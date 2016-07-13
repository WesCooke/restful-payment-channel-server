{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module Server.Config.Types where

import           Server.ChanStore.Client (ChanMapConn)
import           Server.Types

import           Data.Bitcoin.PaymentChannel.Types (BitcoinAmount)

import qualified Network.Haskoin.Transaction as HT
import qualified Network.Haskoin.Crypto as HC
import qualified Crypto.Secp256k1 as Secp
import           Control.Lens.TH (makeLenses)
import qualified Data.ByteString as BS
import           Data.Configurator.Types
import           Common.Common (fromHexString)
import           Data.Ratio
import           Data.String.Conversions (cs)



data App = App
 { _channelStateMap :: ChanMapConn
 , _settleConfig    :: ChanSettleConfig
 , _pubKey          :: HC.PubKey
 , _openPrice       :: BitcoinAmount
 , _fundingMinConf  :: Int
 , _basePath        :: BS.ByteString
 , _bitcoinPushTx   :: (HT.Tx -> IO (Either String HT.TxHash))
 }

-- Template Haskell magic
makeLenses ''App

data BitcoinNet = Mainnet | Testnet3


instance Configured BitcoinNet where
    convert (String "live") = return Mainnet
    convert (String "test") = return Testnet3
    convert (String _) = Nothing


instance Configured HC.Address where
    convert (String text) = HC.base58ToAddr . cs $ text

instance Configured BitcoinAmount where
    convert (Number r) =
        if denominator r /= 1 then Nothing
        else Just . fromIntegral $ numerator r
    convert _ = Nothing

instance Configured HC.PrvKey where
    convert (String text) =
        fmap HC.makePrvKey . Secp.secKey . fromHexString . cs $ text
