module Config.Common where

import           Options.Applicative (Parser, option, metavar, long, help, auto)
import           Database.Persist.Postgresql (ConnectionString)
import qualified Data.ByteString.Char8 as BC

import           Cardano.Api.Typed (SlotNo (SlotNo))

data DatabaseConfig
  = DatabaseConfig { _dbName       :: String
                   , _dbUser       :: String
                   , _dbHost       :: String
                   }
  deriving (Eq, Show)

pgConnectionString :: DatabaseConfig -> ConnectionString
pgConnectionString (DatabaseConfig dbName dbUser dbHost) = BC.pack $ "host=" <> dbHost <> " dbname=" <> dbName <> " user=" <> dbUser

pSlotNo :: Parser SlotNo
pSlotNo = SlotNo
    <$> option auto
          ( long "slot-no"
          <> metavar "WORD64"
          <> help "Slot number to query"
          )
