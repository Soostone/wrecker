{-# LANGUAGE RecordWildCards, ScopedTypeVariables, LambdaCase,
  BangPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Wrecker.Runner where

import Control.Concurrent
import Control.Concurrent.NextRef
import Control.Concurrent.STM
import qualified Control.Concurrent.Thread.BoundedThreadGroup
       as BoundedThreadGroup
import Control.Exception
import qualified Control.Immortal as Immortal
import Control.Monad
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as BSL
import Data.Foldable (for_)
import Data.Function
import qualified Data.HashMap.Strict as H
import Data.HashMap.Strict (HashMap)
import Data.IORef
import Data.List (isInfixOf)
import Data.Maybe
import qualified Graphics.Vty as VTY
import Network.Connection (ConnectionContext)
import qualified Network.Connection as Connection
import System.Exit
import System.IO
import System.Posix.Signals
import System.Timeout
import Wrecker.Logger
import Wrecker.Options
import qualified Wrecker.Recorder as Recorder
import Wrecker.Recorder (Event(..), Recorder)
import Wrecker.Statistics

-- TODO configure whether errors are used in times or not
-- | The 'Environment' holds state necessary to make and record HTTP calls.
data Environment = Environment
    { recorder :: Recorder
      -- ^ The 'Recorder' can be used with the 'record' function to ... record times.
    , context :: ConnectionContext
      -- ^ Provided as a convience, this is a shared TLS context to reuse for
      --   better performance.
    , logger :: Logger
    }

{- | Typically 'wrecker' will control benchmarking actions. However in some situations
     a benchmark might require more control.

     To facilitate more complex scenarios 'wrecker' provide 'newStandaloneRecorder'
     which provides a 'Recorder' and 'Thread' that processes the events, and a
     reference to the current stats.
-}
newStandaloneRecorder :: IO (NextRef AllStats, Immortal.Thread, Recorder)
newStandaloneRecorder = do
    recorder <- Recorder.newRecorder True 10000
    (ref, thread) <- sinkRecorder recorder
    return (ref, thread, recorder)

sinkRecorder :: Recorder -> IO (NextRef AllStats, Immortal.Thread)
sinkRecorder recorder = do
    ref <- newNextRef emptyAllStats
    immortal <- Immortal.createWithLabel "collectEvent" $ \_ -> collectEvent ref recorder
    return (ref, immortal)

updateSampler :: NextRef AllStats -> Event -> IO AllStats
updateSampler !ref !event =
    modifyNextRef ref $ \x ->
        let !new = stepAllStats x (eRunIndex event) (Recorder.name $ eResult event) (eResult event)
        in (new, new)

collectEvent :: NextRef AllStats -> Recorder -> IO ()
collectEvent ref recorder =
    fix $ \next -> do
        mevent <- Recorder.readEvent recorder
        for_ mevent $ \event -> do
            _ <- updateSampler ref event
            next

runAction :: Logger -> Int -> Int -> RunType -> (Environment -> IO ()) -> Environment -> IO ()
runAction logger timeoutTime concurrency runStyle action env = do
    threadLimit <- BoundedThreadGroup.new concurrency
    recorderRef <- newIORef $ recorder env
    let takeRecorder = atomicModifyIORef' recorderRef $ \x -> (Recorder.split x, x)
        actionThread =
            BoundedThreadGroup.forkIO threadLimit $ do
                bracket takeRecorder (\rec -> Recorder.addEvent rec Recorder.End) $ \rec -> do
                    result <- try $ action (env {recorder = rec})
                    case result of
                        Right _ -> return ()
                        Left e -> recordException e
    case runStyle of
        RunCount count -> replicateM_ (count * concurrency) actionThread
        RunTimed time -> void $ timeout (time * 1000000) $ forever actionThread
    mtimeout <- timeout timeoutTime $ BoundedThreadGroup.wait threadLimit
    case mtimeout of
        Nothing -> void $ logError logger $ "Timed out waiting for all " ++ "threads to complete"
        Just () -> return ()
  where
    recordException e =
        case fromException e of
            Just (Recorder.HandledError he) -> do
                void $ logWarn logger $ show he
            _ -> do
                logWarn logger $ show e
                Recorder.addEvent (recorder env) Recorder.RuntimeError

------------------------------------------------------------------------------
---   Generic Run Function
-------------------------------------------------------------------------------
runWithNextVar ::
       Options
    -- ^ The run options as passed from the CLI
    -> (NextRef AllStats -> IO ())
    -- ^ The statistics consumer action. Use this for example to present a summary of the stast
    -> (NextRef AllStats -> IO ())
    -- ^ The final consumer action. Maybe to present a final chart of the stats.
    -> (Environment -> IO ())
    -- ^ The load test action
    -> IO AllStats
runWithNextVar (Options {..}) consumer final action = do
    recorder <- Recorder.newRecorder recordQuery 100000
    context <- Connection.initConnectionContext
    sampler <- newNextRef emptyAllStats
    logger <- newStdErrLogger logLevel logFmt
    -- Collect events and
    forkIO $
        handle (\(e :: SomeException) -> void $ logError logger $ show e) $
        collectEvent sampler recorder
    consumer sampler
    logDebug logger "Starting Runs"
    let env = Environment {..}
    runAction logger timeoutTime concurrency runStyle action env `finally`
        (do logDebug logger "Shutting Down"
            Recorder.stopRecorder recorder
            shutdownLogger logger
            final sampler)
    readLast sampler

-------------------------------------------------------------------------------
---   Non-interactive Rendering
-------------------------------------------------------------------------------
printLastSamples :: Options -> NextRef AllStats -> IO ()
printLastSamples options sampler = printStats options =<< readLast sampler

runNonInteractive :: Options -> (Environment -> IO ()) -> IO AllStats
runNonInteractive options action = do
    let shutdown sampler = do
            putStrLn ""
            hFlush stdout
            hSetBuffering stdout (BlockBuffering (Just 100000000))
            printLastSamples options sampler
            hFlush stdout
            for_ (outputFilePath options) $ \filePath ->
                BSL.writeFile filePath . encode =<< readLast sampler
    runWithNextVar options (const $ return ()) shutdown action

-------------------------------------------------------------------------------
---   Interactive Rendering
-------------------------------------------------------------------------------
printLoop :: Options -> VTY.DisplayContext -> VTY.Vty -> NextRef AllStats -> IO ()
printLoop options context vty sampler =
    fix $ \next ->
        takeNextRef sampler >>= \case
            Nothing -> return ()
            Just allStats -> do
                updateUI (requestNameColumnSize options) (urlDisplay options) context allStats
                VTY.refresh vty
                threadDelay 100000
                next

processInputForCtrlC :: TChan VTY.Event -> IO ThreadId
processInputForCtrlC chan =
    forkIO $
    forever $ do
        event <- atomically $ readTChan chan
        case event of
            VTY.EvKey (VTY.KChar 'c') [VTY.MCtrl] -> raiseSignal sigINT
            _ -> return ()

updateUI :: Maybe Int -> URLDisplay -> VTY.DisplayContext -> AllStats -> IO ()
updateUI nameSize urlDisp displayContext stats =
    VTY.outputPicture displayContext $
    VTY.picForImage $
    VTY.vertCat $ map (VTY.string VTY.defAttr) $ lines $ pprStats nameSize urlDisp stats

runInteractive :: Options -> (Environment -> IO ()) -> IO AllStats
runInteractive options action = do
    vtyConfig <- VTY.standardIOConfig
    vty <- VTY.mkVty vtyConfig
    let output = VTY.outputIface vty
    (width, height) <- VTY.displayBounds output
    displayContext <- VTY.displayContext output (width, height)
    inputThread <- processInputForCtrlC $ VTY._eventChannel $ VTY.inputIface vty
    let shutdown sampler = do
            killThread inputThread
            VTY.shutdown vty
            putStrLn ""
            hSetBuffering stdout (BlockBuffering (Just 100000000))
            printLastSamples options sampler
            hFlush stdout
            for_ (outputFilePath options) $ \filePath ->
                BSL.writeFile filePath . encode =<< readLast sampler
    runWithNextVar
        options
        (\sampler -> void $ forkIO (printLoop options displayContext vty sampler))
        shutdown
        action

-------------------------------------------------------------------------------
---   Main Entry Point
-------------------------------------------------------------------------------
-- | 'run' is the a lower level entry point, compared to 'defaultMain'. Unlike
--    'defaultMain' no command line argument parsing is performed. Instead,
--    'Options' are directly passed in. 'defaultOptions' can be used as a
--    default argument for 'run'.
--
--    Like 'defaultMain', 'run' creates a 'Recorder' and passes it each
--    benchmark.
run :: Options -> [(String, Environment -> IO ())] -> IO (HashMap String AllStats)
run (Options {listTestGroups = True}) actions = do
    showTestGroups actions
    return H.empty
run options actions = do
    hSetBuffering stderr LineBuffering
    fmap H.fromList . forM actions $ \(groupName, action) -> do
        if (match options `isInfixOf` groupName)
            then do
                putStrLn groupName
                (groupName, ) <$>
                    case displayMode options of
                        NonInteractive -> runNonInteractive options action
                        Interactive -> runInteractive options action
            else return (groupName, emptyAllStats)

showTestGroups :: [(String, Environment -> IO ())] -> IO ()
showTestGroups [] = do
    hSetBuffering stderr LineBuffering
    hPutStrLn stderr noTestsGroupsError
    exitFailure
  where
    noTestsGroupsError =
        "This executable has no pre-configured tests groups. \n\n" ++
        "In order to run your customized tests, you need to implement your own Main module and call Wrecker.Runner.run \n" ++
        "and provide a list of actions to execute. Please refer to the README file for instructions."
showTestGroups tests =
    mapM_
        (\(i, (groupName, _)) -> putStrLn (">> " ++ show @Int i ++ ". " ++ groupName))
        (zip [1 ..] tests)

{-| Run a single benchmark
-}
runOne :: Options -> (Environment -> IO ()) -> IO AllStats
runOne options f =
    let key = ""
    in fromMaybe (error "runOne: impossible!") . H.lookup key <$> run options [(key, f)]
