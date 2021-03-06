# Building a Profiling Client with `wrecker`

`wrecker` is intended to benchmark HTTP calls inline with other forms of
processing. This allows for complex the interactions necessary to benchmark
certain API endpoints.

## TL;DR

`wrecker` lets you build elegant API clients that you can use for profiling.

Here is the the final benchmark utlizing the typed REST client we will build.

    testScript :: Int -> ConnectionContext -> Recorder -> IO ()
    testScript port cxt rec = withSession cxt rec $ \sess -> do
      Root { products
           , login
           , checkout
           }             <- get sess (rootRef port)
      firstProduct : _   <- get sess products
      userRef            <- rpc sess login
                                      ( Credentials
                                        { userName = "a@example.com"
                                        , password = "password"
                                        }
                                      )
      User { usersCart } <- get sess userRef
      Cart { items }     <- get sess usersCart

      insert sess items firstProduct
      rpc sess checkout cart

If this doesn't make sense on inspection, that is okay. This file builds up all
the necessary utilities and documents every line.

Most of the code in this file is "generic." It is the type of boilerplate you
make once for an API client.

You don't need to make a polished typed API client to use `wrecker`;
just look at TODO_MAKE_AESON_LENS_EXAMPLE.

## Outline
 - [Boring Haskell Prelude](#Boring_Haskell_Prelude)
 - [Make a Somewhat Generic JSON API](#Make_a_Somewhat_Generic_JSON_API)
 - [Make a Somewhat Generic REST API](#Make_a_Somewhat_Generic_REST_API)
 - [The Example API](#The_Example_API)
 - [Profiling Script](#Profiling_Script)

## <a name="Boring_Haskell_Prelude"> Boring Haskell Prelude

This is Haskell, so first we turn on the extensions we would like to use.

```haskell
{-# LANGUAGE NamedFieldPuns, DeriveGeneric, OverloadedStrings, CPP #-}
```

- `NamedFieldPuns` will let us destructure records conveniently. 
- `DeriveAnyClass` and `DeriveGeneric` are used turned on so the compiler
  can generate the JSON conversion functions for us automatically.
- `OverloadedStrings` is a here so Redditors don't yell at me for using
  `String` instead of `Text`.
- `CPP`...ignore that...

```haskell
#ifndef _CLIENT_IS_MAIN_
module Client where
#endif
```
Not the drones...

### The Essence of `wrecker`

```haskell
import Wrecker (defaultMain, Environment)
```

- `defaultMain` is one of two entry points `wrecker` provides (the other is
  `run`). `defaultMain` performs command line argument parsing for us, and
  runs the benchmarks with the provided options.
- `Environment` contains the necessary state to record the times of
  requests and it has a preallocated TLS context.

```haskell
import Data.Aeson
```
We need JSON, so of course we are using `aeson`.

```haskell
import Network.Wreq (Response)
import Network.Wreq.Wrecker (Session)
import qualified Network.Wreq.Wrecker as WW
```
`wrecker` provides a wrapped version of `Network.Wreq.Session` called
`Network.Wreq.Wrecker`. Importing is the quickest way to write a benchmark with
`wrecker`

#### Other packages you can mostly ignore
```haskell
import GHC.Generics
import Data.Text as T
import Network.HTTP.Client (responseBody)
```

## <a name="Make_a_Somewhat_Generic_JSON_API"> Make a Somewhat Generic JSON API

`wreq` is pretty easy to use for JSON APIs, but it could be easier. Here we make
a quick wrapper around `wreq`, specialized to JSON.

### The Envelope

We wrap all JSON sent to and from the server in the envelope.

The envelope is serialized to JSON with the following format
```json
{"value" : RESPONSE_SPECIFIC_OUTPUT }
```
It is represented in Haskell as
```haskell
data Envelope a = Envelope { value :: a }
  deriving (Show, Eq, Generic)

instance FromJSON a => FromJSON (Envelope a)
instance ToJSON a => ToJSON (Envelope a) 
```

The `Envelope` only exists to transmit data between the server and the browser.

- We wrap values going to the server in an `Envelope`.

  ```haskell
  toEnvelope :: ToJSON a => a -> Value
  toEnvelope = toJSON . Envelope
  ```

- We unwrap values coming from the server in `Envelope`.

  ```haskell
  fromEnvelope :: FromJSON a => IO (Response (Envelope a)) -> IO a
  fromEnvelope x = fmap (value . responseBody) x
  ```

- We wrap inputs and unwrap outputs so we can wrap a whole function.

  ```haskell
  liftEnvelope :: (ToJSON a, FromJSON b)
               => (Value -> IO (Response (Envelope b)))
               -> (a     -> IO b)
  liftEnvelope f = fromEnvelope . f . toEnvelope
  ```

### Hide the Envelope

We hide the `Envelope` in JSON specialized `get`'s and `post`'s.

```haskell
jsonGet :: FromJSON a => Session -> Text -> IO a
jsonGet sess url = fromEnvelope $ WW.getJSON sess (T.unpack url)

jsonPost :: (ToJSON a, FromJSON b) => Session -> Text -> a -> IO b
jsonPost sess url = liftEnvelope $ WW.postJSON sess (T.unpack url)
```

## <a name="Make_a_Somewhat_Generic_REST_API"> Make a Somewhat Generic REST API

### Resource References
Working with JSON is okay, but this is Haskell so we would rather work with
types.

We represent resource URLs using the type `Ref`.
```haskell
data Ref a = Ref { unRef :: Text }
  deriving (Show, Eq)
```

`Ref` is nothing more than a `Text` wrapper (the value there is the URL). `Ref`
has a phantom type `a`, which enables us to talk about different types of resources.

`Ref a`'s `FromJSON` instance wraps a `Text` value, after scrutinizing the JSON `Value` to ensure it is `Text`.

```haskell
instance FromJSON (Ref a) where
  parseJSON = withText "FromJSON (Ref a)" (return . Ref)
```

The `ToJSON` is just the reverse.

```haskell
instance ToJSON (Ref a) where
  toJSON (Ref x) = toJSON x
```

In addition to resources, our API has ad-hoc RPC calls. RPC calls are also
represented as a URL.

### Adhoc RPC

```haskell
data RPC a b = RPC Text
  deriving (Show, Eq)

instance FromJSON (RPC a b) where
  parseJSON = withText "FromJSON (Ref a)" (return . RPC)
```

### REST API Actions

We utilize our `jsonGet` and `jsonPost` functions, and make specialized versions
for our more specific REST and RPC calls.

- `get` takes a `Ref a` and returns an `a`. The `a` could be something
  like `Cart`, or it could be a list like `[Ref a]`.

  ```haskell
  get :: FromJSON a => Session -> Ref a -> IO a
  get sess (Ref url) = jsonGet sess url
  ```

- `insert` takes a `Ref` to a list and appends an item to it. It returns the
  reference that you passed in because, why not.

  ```haskell
  insert :: ToJSON a => Session -> Ref [a] -> a -> IO (Ref [a])
  insert sess (Ref url) = jsonPost sess url
  ```

- `rpc` unpacks the URL for the RPC endpoint and `POST`s the input, returning
  the output.

  ```haskell
  rpc :: (ToJSON a, FromJSON b) => Session -> RPC a b -> a -> IO b
  rpc sess (RPC url) = jsonPost sess url
  ```

## <a name="The_Example_API"> The Example API

The API requires an initial call to the "/root" to obtain the URLs for
subsequent calls.

```haskell
rootRef :: Int -> Ref Root
rootRef port = Ref $ T.pack $ "http://localhost:" ++ show port ++ "/root"
```

### API Response Types

Calling `GET` on "/root" returns the following JSON  

```json
{ "products" : "http://localhost:3000/products"
, "carts"    : "http://localhost:3000/carts"
, "users"    : "http://localhost:3000/users"
, "login"    : "http://localhost:3000/login"
, "checkout" : "http://localhost:3000/checkout"
}
```

Which will deserialize to

```haskell                                                
data Root = Root                           
  { products :: Ref [Ref Product]          
  , carts    :: Ref [Ref Cart   ]          
  , users    :: Ref [Ref User   ]          
  , login    :: RPC Credentials (Ref User)
  , checkout :: RPC (Ref Cart)  ()         
  } deriving (Eq, Show, Generic)

instance FromJSON Root
```

Since the JSON is so uniform, we can use `aeson`'s generic instances.

Calling `GET` on a `Ref Product` or "/products/:id" gives

```json
{ "summary" : "shirt" }
```

Which will deserialize to

```haskell
data Product = Product                     
  { summary :: Text                        
  } deriving (Eq, Show, Generic)

instance FromJSON Product
```

Calling `GET` on a `Ref Cart` or "/carts/:id" gives

```json
{ "items" : ["http://localhost:3000/products/0"] }
```

...

```haskell
data Cart = Cart                           
  { items :: Ref [Ref Product]             
  } deriving (Eq, Show, Generic)

instance FromJSON Cart
```
Calling `GET` on a `Ref User` or "/users/:id" gives

```json
{ "cart"     : "http://localhost:3000/carts/0"
, "username" : "example"
}
```

```haskell
data User = User                           
  { cart     :: Ref Cart                   
  , username :: Text                       
  } deriving (Eq, Show, Generic)

instance FromJSON User
```

## RPC Types

The only additional type that we need is the input for the `login` RPC, mainly the `Credentials` type.

```json
{ "password" : "password"
, "userid"   : "a@example.com"
}
```

```haskell
data Credentials = Credentials             
  { password :: Text                       
  , userid   :: Text                       
  } deriving (Eq, Show, Generic)

instance ToJSON Credentials
```

## <a name="Profiling_Script"> Profiling Script

We can now easily write our first script!

```haskell
testScript :: Int -> Environment -> IO ()
testScript port = WW.withWreq $ \sess -> do
```
Bootstrap the script and get all the URLs for the endpoints. Unpack
`products`, `login` and `checkout` refs for use later down.

```haskell
  Root { products
       , login
       , checkout
       } <- get sess (rootRef port)
```
We get all products and name the first one.

```haskell
  firstProduct : _ <- get sess products
```

Login and get the user's ref.

```haskell
  userRef <- rpc sess login
                        ( Credentials
                           { userid   = "a@example.com"
                           , password = "password"
                           }
                        )

```
Get the user and unpack the user's cart.

```haskell
  User { cart } <- get sess userRef
```
Get the cart and unpack the items.
```haskell
  Cart { items } <- get sess cart
```
Add the first product to the user's cart's items.
```haskell
  insert sess items firstProduct
```
Checkout.
```haskell
  rpc sess checkout cart
```

Port is hard coded to 3000 for this example.

```haskell
benchmarks :: Int -> IO [(String, Environment -> IO ())]
benchmarks port = do
  -- Create a TLS context once
  return [("test0", testScript port)]

main :: IO ()
main = defaultMain =<< benchmarks 3000
```
