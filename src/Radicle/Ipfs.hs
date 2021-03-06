-- | Functions to talk to the IPFS API
module Radicle.Ipfs
    ( IpfsException(..)
    , ipldLink
    , parseIpldLink
    , IpnsId
    , Address(..)
    , addressToText
    , addressFromText

    , VersionResponse(..)
    , version

    , KeyGenResponse(..)
    , keyGen

    , DagPutResponse(..)
    , dagPut
    , dagGet
    , pinAdd

    , namePublish
    , NameResolveResponse(..)
    , nameResolve

    , PubsubMessage(..)
    , publish
    , subscribe
    ) where

import           Protolude hiding (TypeError, catch, catches, try)

import           Control.Exception.Safe
import           Control.Monad.Fail
import           Control.Monad.Trans.Resource
import           Data.Aeson (FromJSON, ToJSON, (.:), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString.Multibase as Multibase
import           Data.Conduit ((.|))
import qualified Data.Conduit as C
import qualified Data.Conduit.Attoparsec as C
import qualified Data.Conduit.Combinators as C
import qualified Data.HashMap.Strict as HashMap
import           Data.IPLD.CID
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Lens.Micro ((.~), (^.))
import           Network.HTTP.Client
                 (HttpException(..), HttpExceptionContent(..))
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client as Http
import qualified Network.HTTP.Conduit as HTTP
import qualified Network.Wreq as Wreq
import           System.Environment (lookupEnv)

data IpfsException
  = IpfsException Text
  | IpfsExceptionErrResp Text
  | IpfsExceptionErrRespNoMsg
  -- | The request to the IPFS daemon timed out. The constructor
  -- parameter is the API path.
  | IpfsExceptionTimeout Text
  -- | JSON response from the IPFS Api cannot be parsed. First
  -- argument is the request path, second argument the JSON parsing
  -- error
  | IpfsExceptionInvalidResponse Text Text
  -- | The IPFS daemon is not running.
  | IpfsExceptionNoDaemon
  -- | Failed to parse IPLD document returned by @dag/get@ with
  -- 'Aeson.fromJSON'. First argument is the IPFS address, second argument is
  -- the Aeson parse error.
  | IpfsExceptionIpldParse Address Text
  deriving (Show)

instance Exception IpfsException where
    displayException e = "ipfs: " <> case e of
        IpfsException msg -> toS msg
        IpfsExceptionNoDaemon -> "Cannot connect to " <> name
        IpfsExceptionInvalidResponse url _ -> "Cannot parse " <> name <> " response for " <> toS url
        IpfsExceptionTimeout apiPath -> name <> " took too long to respond for " <> toS apiPath
        IpfsExceptionErrResp msg -> toS msg
        IpfsExceptionErrRespNoMsg -> name <> " failed with no error message"
        IpfsExceptionIpldParse addr parseError ->
            toS $ "Failed to parse IPLD document " <> addressToText addr <> ": " <> parseError
      where
        name = "Radicle IPFS daemon"

-- | Catches 'HttpException's and re-throws them as 'IpfsException's.
--
-- @path@ is the IPFS API path that is added to some errors.
mapHttpException :: Text -> IO a -> IO a
mapHttpException path io = catch io (throw . mapHttpExceptionData)
  where
    mapHttpExceptionData :: HttpException -> IpfsException
    mapHttpExceptionData = \case
        Http.HttpExceptionRequest _ content -> mapHttpExceptionContent content
        _ -> IpfsExceptionErrRespNoMsg

    mapHttpExceptionContent :: HttpExceptionContent -> IpfsException
    mapHttpExceptionContent = \case
        (Http.StatusCodeException _
          (Aeson.decodeStrict ->
             Just (Aeson.Object (HashMap.lookup "Message" ->
                     Just (Aeson.String msg))))) -> (IpfsExceptionErrResp msg)
        Http.ResponseTimeout -> IpfsExceptionTimeout path
        ConnectionFailure _ -> IpfsExceptionNoDaemon
        _ -> IpfsExceptionErrRespNoMsg

-- | Given a CID @"abc...def"@ it returns a IPLD link JSON object
-- @{"/": "abc...def"}@.
ipldLink :: CID -> Aeson.Value
ipldLink cid = Aeson.object [ "/" .= cidToText cid ]

-- | Parses JSON values of the form @{"/": "abc...def"}@ where
-- @"abc...def"@ is a valid CID.
parseIpldLink :: Aeson.Value -> Aeson.Parser CID
parseIpldLink =
    Aeson.withObject "IPLD link" $ \o -> do
        cidText <- o .: "/"
        case cidFromText cidText of
            Left e    -> fail $ "Invalid CID: " <> e
            Right cid -> pure cid

--------------------------------------------------------------------------
-- * IPFS types
--------------------------------------------------------------------------

type IpnsId = Text

-- | Addresses either an IPFS content ID or an IPNS ID.
data Address
    = AddressIpfs CID
    | AddressIpns IpnsId
    deriving (Eq, Show, Read, Generic)

-- This is the same representation of IPFS paths as used by the IPFS CLI and
-- daemon. Either @"/ipfs/abc...def"@ or @"/ipns/abc...def"@.
addressToText :: Address -> Text
addressToText (AddressIpfs cid)    = "/ipfs/" <> cidToText cid
addressToText (AddressIpns ipnsId) = "/ipns/" <> ipnsId

-- | Partial inverse of 'addressToText'.
addressFromText :: Text -> Maybe Address
addressFromText t =
        (AddressIpfs <$> maybeAddress)
    <|> (AddressIpns <$> T.stripPrefix "/ipns/" t)
  where
    maybeAddress = do
        cidText <- T.stripPrefix "/ipfs/" t
        case cidFromText cidText of
            Left _    -> Nothing
            Right cid -> Just cid


--------------------------------------------------------------------------
-- * IPFS node API
--------------------------------------------------------------------------

newtype VersionResponse = VersionResponse Text

instance FromJSON VersionResponse where
    parseJSON = Aeson.withObject "VersionResponse" $ \o -> do
        v <- o .: "Version"
        pure $ VersionResponse v

version :: IO VersionResponse
version = ipfsHttpGet "version" []

data PubsubMessage = PubsubMessage
    { messageTopicIDs :: [Text]
    , messageData     :: ByteString
    , messageFrom     :: ByteString
    , messageSeqno    :: ByteString
    } deriving (Eq, Show)

instance FromJSON PubsubMessage where
    parseJSON = Aeson.withObject "PubsubMessage" $ \o -> do
        messageTopicIDs <- o .: "topicIDs"
        Right messageData <- o .: "data" <&> T.encodeUtf8 <&> Multibase.decodeBase64
        Right messageFrom <- o .: "from" <&> T.encodeUtf8 <&> Multibase.decodeBase64
        Right messageSeqno <- o .: "seqno" <&> T.encodeUtf8 <&> Multibase.decodeBase64
        pure PubsubMessage {..}

-- | Subscribe to a topic and call @messageHandler@ on every message.
-- The IO action blocks while we are subscribed. To stop subscription
-- you need to kill the thread the subscription is running in.
subscribe :: Text -> (PubsubMessage -> IO ()) -> IO ()
subscribe topic messageHandler = runResourceT $ do
    mgr <- liftIO $ HTTP.newManager HTTP.defaultManagerSettings
    url <- liftIO $ ipfsApiUrl "pubsub/sub"
    req <- HTTP.parseRequest (toS url) <&>
        HTTP.setQueryString
        [ ("arg", Just $ T.encodeUtf8 topic)
        , ("encoding", Just "json")
        , ("stream-channels", Just "true")
        ]
    body <- HTTP.responseBody <$> HTTP.http req mgr
    C.runConduit $ body .| fromJSONC .| C.mapM_ (liftIO . messageHandler) .| C.sinkNull
    pure ()
  where
    fromJSONC :: (MonadThrow m, Aeson.FromJSON a) => C.ConduitT ByteString a m ()
    fromJSONC = jsonC .| C.mapM parseThrow

    jsonC :: (MonadThrow m) => C.ConduitT ByteString Aeson.Value m ()
    jsonC = C.peekForever (C.sinkParser Aeson.json >>= C.yield)

    parseThrow :: (MonadThrow m, Aeson.FromJSON a) => Aeson.Value -> m a
    parseThrow value = do
        case Aeson.fromJSON value of
            Aeson.Error err -> throwString err
            Aeson.Success a -> pure a


-- | Publish a message to a topic.
publish :: Text -> LByteString -> IO ()
publish topic message =
     void $ ipfsHttpPost' "pubsub/pub" [("arg", topic)] "data" message

newtype KeyGenResponse = KeyGenResponse IpnsId

keyGen :: Text -> IO KeyGenResponse
keyGen name = ipfsHttpGet "key/gen" [("arg", name), ("type", "ed25519")]

instance FromJSON KeyGenResponse where
    parseJSON = Aeson.withObject "ipfs key/gen" $ \o ->
        KeyGenResponse <$> o .: "Id"


newtype DagPutResponse
    = DagPutResponse CID

-- | Put and pin a dag node.
dagPut :: ToJSON a => a -> IO DagPutResponse
dagPut obj = ipfsHttpPost "dag/put" [("pin", "true")] "arg" (Aeson.encode obj)

instance FromJSON DagPutResponse where
    parseJSON = Aeson.withObject "v0/dag/put response" $ \o -> do
        cidObject <- o .: "Cid"
        cidText <- cidObject .: "/"
        case cidFromText cidText of
            Left _    -> fail "invalid CID"
            Right cid -> pure $ DagPutResponse cid

newtype PinResponse = PinResponse [CID]

instance FromJSON PinResponse where
  parseJSON = Aeson.withObject "v0/pin/add response" $ \o -> do
    cidTexts <- o .: "Pins"
    case traverse cidFromText cidTexts of
      Left _     -> fail "invalid CID"
      Right cids -> pure $ PinResponse cids

-- | Pin objects to local storage.
pinAdd :: Address -> IO PinResponse
pinAdd addr = ipfsHttpGet "pin/add" [("arg", addressToText addr)]

-- | Get a dag node.
dagGet :: FromJSON a => Address -> IO a
dagGet addr = do
    result <- ipfsHttpGet "dag/get" [("arg", addressToText addr)]
    case Aeson.fromJSON result of
        Aeson.Error err -> throw $ IpfsExceptionIpldParse addr (toS err)
        Aeson.Success a -> pure a

namePublish :: IpnsId -> Address -> IO ()
namePublish ipnsId addr = do
    _ :: Aeson.Value <- ipfsHttpGet "name/publish" [("arg", addressToText addr), ("key", ipnsId)]
    pure ()


newtype NameResolveResponse
    = NameResolveResponse CID

nameResolve :: IpnsId -> IO NameResolveResponse
nameResolve ipnsId = ipfsHttpGet "name/resolve" [("arg", ipnsId), ("recursive", "true")]

instance FromJSON NameResolveResponse where
    parseJSON = Aeson.withObject "v0/name/resolve response" $ \o -> do
        path <- o .: "Path"
        case addressFromText path of
            Nothing                -> fail "invalid IPFS path"
            Just (AddressIpfs cid) -> pure $ NameResolveResponse cid
            Just _                 -> fail "expected /ipfs path"


--------------------------------------------------------------------------
-- * IPFS Internal
--------------------------------------------------------------------------

ipfsHttpGet
    :: FromJSON a
    => Text  -- ^ Path of the endpoint under "/api/v0/"
    -> [(Text, Text)] -- ^ URL query parameters
    -> IO a
ipfsHttpGet path params = mapHttpException path $ do
    let opts = Wreq.defaults & Wreq.params .~ params
    url <- ipfsApiUrl path
    res <- Wreq.getWith opts (toS url)
    getJsonResponseBody path res

ipfsHttpPost
    :: FromJSON a
    => Text  -- ^ Path of the endpoint under "/api/v0/"
    -> [(Text, Text)] -- ^ URL query parameters
    -> Text  -- ^ Name of the argument for payload
    -> LByteString -- ^ Payload argument
    -> IO a
ipfsHttpPost path params payloadArgName payload = mapHttpException path $ do
    res <- ipfsHttpPost' path params payloadArgName payload
    getJsonResponseBody path res

ipfsHttpPost'
    :: Text  -- ^ Path of the endpoint under "/api/v0/"
    -> [(Text, Text)] -- ^ URL query parameters
    -> Text  -- ^ Name of the argument for payload
    -> LByteString -- ^ Payload argument
    -> IO (Wreq.Response LByteString)
ipfsHttpPost' path params payloadArgName payload = mapHttpException path $ do
    let opts = Wreq.defaults & Wreq.params .~ params
    url <- ipfsApiUrl path
    Wreq.postWith opts (toS url) (Wreq.partLBS payloadArgName payload)

ipfsApiUrl :: Text -> IO Text
ipfsApiUrl path = do
    baseUrl <- fromMaybe "http://localhost:9301" <$> lookupEnv "RAD_IPFS_API_URL"
    pure $ toS baseUrl <> "/api/v0/" <> path

-- | Parses response body as JSON and returns the parsed value. @path@
-- is the IPFS API the response was obtained from. Throws
-- 'IpfsExceptionInvalidResponse' if parsing fails.
getJsonResponseBody :: FromJSON a => Text -> Wreq.Response LByteString -> IO a
getJsonResponseBody path res = do
    jsonRes <- Wreq.asJSON res `catch`
        \(Wreq.JSONError msg) -> throw $ IpfsExceptionInvalidResponse path (toS msg)
    pure $ jsonRes ^. Wreq.responseBody
