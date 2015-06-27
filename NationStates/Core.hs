{-# LANGUAGE OverloadedStrings, Rank2Types #-}

-- | Low-level tools for querying the NationStates API.
--
-- Most of the time, you should use the high-level wrappers in e.g.
-- "NationStates.Nation" instead. But if you need something not provided
-- by these wrappers, then feel free to use this module directly.

module NationStates.Core (

    -- * Requests
    NS,
    makeNS,
    makeNS',
    requestNS,
    apiVersion,

    -- * Query strings
    Query(..),

    -- * Connection manager
    Context(..),

    -- * Utilities
    splitDropBlanks,
    readMaybe,
    expect,
    expected,

    -- * Data structures
    module NationStates.Types,

    ) where


import qualified Data.ByteString.Char8 as BC
import Data.Functor.Compose
import Data.Foldable (toList)
import Data.List
import Data.List.Split
import Data.Monoid
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import Network.HTTP.Client
import qualified Network.HTTP.Types as HTTP
import Text.Read
import Text.XML.Light

import NationStates.Types


-- | A request to the NationStates API.
--
-- * Construct an @NS@ using 'makeNS' or 'makeNS''.
-- * Compose @NS@ values using the 'Applicative' interface.
-- * Execute an @NS@ using 'requestNS'.
--
-- This type wraps a query string, along with a function that parses the
-- response. The funky type machinery keeps these two parts in sync, as
-- long as you stick to the 'Applicative' interface.
--
-- @
-- type NS a = ('Query', Query -> 'Element' -> a)
-- @
type NS = Compose ((,) Query) (Compose ((->) Query) ((->) Element))


-- | Construct a request for a single shard.
--
-- For example, this code requests the
-- <https://www.nationstates.net/cgi-bin/api.cgi?nation=testlandia&q=motto "motto">
-- shard:
--
-- @
-- motto :: NS String
-- motto = makeNS \"motto\" Nothing \"MOTTO\"
-- @
--
-- For more complex requests (e.g. nested elements), try 'makeNS'' instead.
makeNS
    :: String
        -- ^ Shard name
    -> String
        -- ^ XML element name
    -> NS String
makeNS shard elemName = makeNS' shard Nothing [] parse
  where
    parse _ = strContent . fromMaybe errorMissing . findChild (unqual elemName)
    errorMissing = error $ "missing <" ++ elemName ++ "> element"


-- | Construct a request for a single shard.
makeNS'
    :: String
        -- ^ Shard name
    -> Maybe Integer
        -- ^ Shard ID
    -> [(String, String)]
        -- ^ List of options
    -> (Query -> Element -> a)
        -- ^ Function for parsing the response
    -> NS a
makeNS' name maybeId options parse = Compose
    (Query {
        queryShards = Map.singleton name (Set.singleton maybeId),
        queryOptions = Map.fromList options
    }, Compose parse)


-- | Perform a request on the NationStates API.
requestNS
    :: Maybe (String, String)
        -- ^ Request type
    -> NS a
        -- ^ Set of shards to request
    -> Context
        -- ^ Connection manager
    -> IO a
requestNS kindAndName (Compose (q, Compose p)) c
    = parse . responseBody <$>
        (contextRateLimit c $ httpLbs req (contextManager c))
  where
    parse = p q . fromMaybe (error "invalid response") . parseXMLDoc
    req = initRequest {
        queryString
            = HTTP.renderQuery True (HTTP.toQuery $
                toList kindAndName ++ [("q", shards), ("v", show apiVersion)])
            <> BC.pack options,
        requestHeaders
            = ("User-Agent", BC.pack $ contextUserAgent c)
            : requestHeaders initRequest
        }
    (shards, options) = queryToUrl q

initRequest :: Request
Just initRequest = parseUrl "https://www.nationstates.net/cgi-bin/api.cgi"


-- | The version of the NationStates API used by this package.
--
-- Every request to NationStates includes this number. This means that
-- if the response format changes, existing code will continue to work
-- under the old API.
--
-- This number should match the current API version, as given by
-- <https://www.nationstates.net/cgi-bin/api.cgi?a=version>. If not,
-- please file an issue.
apiVersion :: Integer
apiVersion = 7


-- | Keeps track of rate limits and TLS connections.
--
-- You should create a single 'Context' at the start of your program,
-- then share it between multiple threads and requests.
data Context = Context {
    contextManager :: Manager,
    contextRateLimit :: forall a. IO a -> IO a,
    contextUserAgent :: String
    }


-- | Keeps track of the set of shards to request.
data Query = Query {
    queryShards :: Map String (Set (Maybe Integer)),
    queryOptions :: Map String String
    } deriving Show

instance Monoid Query where
    mempty = Query mempty mempty
    mappend a b = Query {
        queryShards = Map.unionWith Set.union
            (queryShards a) (queryShards b),
        queryOptions = Map.unionWithKey mergeOptions
            (queryOptions a) (queryOptions b)
        }
      where
        mergeOptions key _ _
            = error $ "conflicting values for option " ++ show key


queryToUrl :: Query -> (String, String)
queryToUrl q = (shards, options)
  where
    shards = intercalate "+" [ name ++ foldMap (\i -> "-" ++ show i) maybeId |
        (name, is) <- Map.toList $ queryShards q,
        maybeId <- Set.toList is ]
    options = concat [ ";" ++ k ++ "=" ++ v |
        (k, v) <- Map.toList $ queryOptions q ]


-- | Split a string by a separator, dropping empty substrings.
--
-- >>> splitDropBlanks "," "the_vines,motesardo-east_adanzi,yellowapple"
-- ["the_vines", "montesardo-east_adanzi", "yellowapple"]
--
-- >>> splitDropBlanks "," ""
-- []
splitDropBlanks :: Eq a => [a] -> [a] -> [[a]]
splitDropBlanks = split . dropBlanks . dropDelims . onSublist

-- | Parse an input string using the given parser function.
--
-- If parsing fails, raise an 'error'.
--
-- >>> expect "integer" readMaybe "42" :: Integer
-- 42
--
-- >>> expect "integer" readMaybe "butts" :: Integer
-- *** Exception: invalid integer: "butts"
expect :: String -> (String -> Maybe a) -> String -> a
expect want parse = fromMaybe <$> expected want <*> parse

-- | Raise an 'error'.
--
-- >>> expected "integer" "butts"
-- *** Exception: invalid integer: "butts"
expected :: String -> String -> a
expected want s = error $ "invalid " ++ want ++ ": " ++ show s
