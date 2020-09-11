{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Api where

import Config (Config (..))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Logger (runStdoutLoggingT)
import Data.Char (isAlphaNum)
import Data.Functor (void)
import Data.Pool (Pool)
import Data.Proxy (Proxy (Proxy))
import qualified Data.Text as T
import Database (Bearer (Bearer), NamedToken (UserCode), Refresh (Refresh), upsertToken)
import Database.Persist.Sql (SqlBackend)
import Database.Persist.Sqlite (runSqlPool)
import GHC.Generics (Generic)
import Servant
  ( Headers,
    JSON,
    NoContent (NoContent),
    QueryParam,
    StdMethod (GET),
    Verb,
    addHeader,
    (:>),
  )
import Servant.API (Get)
import Servant.API.Generic (ToServantApi, genericApi, (:-))
import Servant.API.Header (Header)
import Servant.Server (Application)
import Servant.Server.Generic (AsServerT, genericServe)
import System.Random (randomRIO)
import Url (Url (Url), urlEncode)

genRandomState :: IO T.Text
genRandomState = T.pack <$> go 32 []
  where
    go :: Int -> String -> IO String
    go 0 acc = pure acc
    go n acc = do
      char <- randomRIO ('0', 'z')
      if isAlphaNum char
        then go (n - 1) (char : acc)
        else go n acc

type NoContentWithLocation = Headers (Header "Location" T.Text ': '[]) NoContent

type Redirect302 = Verb 'GET 302 '[JSON] NoContentWithLocation

data Routes route = Routes
  { _authorize :: route :- "authorize" :> Redirect302,
    _oauth2callback :: route :- "oauth2" :> "callback" :> QueryParam "code" T.Text :> QueryParam "state" T.Text :> QueryParam "scope" T.Text :> Get '[JSON] ()
  }
  deriving (Generic)

api :: Proxy (ToServantApi Routes)
api = genericApi (Proxy :: Proxy Routes)

-- TODO:
-- - IO should probably be a `Sem r a` or Transformer equivalent?
handlers :: MonadIO m => Config -> Pool SqlBackend -> Routes (AsServerT m)
handlers Config {..} pool =
  Routes
    { _authorize =
        -- TODO:
        -- - Need to provide a CSRF safe `state` to the url
        return (addHeader url NoContent :: NoContentWithLocation),
      -- TODO:
      -- - Compare state to previous state (see below)
      -- - Store the scope as `Text` in the database
      -- - Should we POST the token back to the server?
      _oauth2callback =
        -- \mCode mState mScope -> do
        \mCode _ _ -> case mCode of
          Just code -> liftIO . runStdoutLoggingT . void $ runSqlPool (upsertToken UserCode (Bearer code) (Refresh "...")) pool
          Nothing -> pure ()
          -- TODO:
          -- - GET /subscribers
          -- - GET /followers
    }
  where
    url =
      urlEncode $
        Url
          "https://id.twitch.tv/oauth2/authorize"
          [ ("client_id", clientId),
            ( "redirect_uri",
              "http://localhost:"
                <> (T.pack . show) portNumber
                <> "/oauth2/callback"
            ),
            ("response_type", "code"),
            ("scope", requiredScopes)
          ]

app :: Config -> Pool SqlBackend -> Application
app config pool = genericServe (handlers config pool)
