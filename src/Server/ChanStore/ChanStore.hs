module Server.ChanStore.ChanStore where

import           DiskStore
import           Data.Bitcoin.PaymentChannel.Types
import           Data.Bitcoin.PaymentChannel.Util (deserEither, unsafeUpdateRecvState)

import qualified Network.Haskoin.Transaction as HT
import qualified Network.Haskoin.Crypto as HC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Binary as Bin

import qualified STMContainers.Map as Map
import qualified ListT as LT
import           Control.Concurrent.STM (STM)
import           Data.Time.Clock (UTCTime)

markAsSettlingAndGetIfOpen m k = do
    maybeItem <- mapGetState m markIt k
    case maybeItem of
        Nothing -> error "Tried to mark non-existing channel state item as settling"
        Just (ReadyForPayment cs) -> return $ Just cs
        _ -> return Nothing
    where markIt (ReadyForPayment cs) = SettlementInProgress cs
          markIt s@(SettlementInProgress _) = s
          markIt s@(ChannelSettled _) = s

-- | Important note: does not support 'LockTimeBlockHeight'
--      TODO: figure out if we even want to accept 'LockTimeBlockHeight' as an expiration date at all
-- Get keys for all channel states with an expiration date later than the specified 'UTCTime'
channelsExpiringBefore :: UTCTime -> ChannelMap -> STM [HT.TxHash]
channelsExpiringBefore currentTimeIsh (DiskMap _ m) =
    map getKey .
    filter (chanExpiresBefore . csState . getItem) .
    filter (isOpen . getItem)
    <$> LT.toList (Map.stream m) where
        chanExpiresBefore = expiresEarlierThan currentTimeIsh . getExpirationDate
        getItem = itemContent . snd
        getKey = fst

expiresEarlierThan :: UTCTime -> BitcoinLockTime -> Bool
expiresEarlierThan _        (LockTimeBlockHeight _) = error "LockTimeBlockHeight not supported"
expiresEarlierThan circaNow (LockTimeDate expDate) = circaNow > expDate

-- settleIt

-- |Holds state for payment channel
data ChanState =
    ReadyForPayment {
        csState          :: ReceiverPaymentChannel
    } |
    ChannelSettled {
        csSettlementTxId :: HT.TxHash
    } |
    SettlementInProgress {
        csSettlingState :: ReceiverPaymentChannel
    }

isSettled :: ChanState -> Bool
isSettled (ChannelSettled _) = True
isSettled _ = False

isOpen :: ChanState -> Bool
isOpen (ReadyForPayment _) = True
isOpen _ = False

type ChannelMap = DiskMap HT.TxHash ChanState

-- data ChanStoreOp =
--     Get    HT.TxHash |
--     Create

newChanMap :: FilePath -> IO ChannelMap
newChanMap = newDiskMap


getChanState :: ChannelMap -> HT.TxHash -> STM (Maybe ChanState)
getChanState = getItem

addChanState :: ChannelMap -> HT.TxHash -> ReceiverPaymentChannel -> STM ()
addChanState chanMap key chanState =
    addItem chanMap key (ReadyForPayment chanState)

updateChanState :: ChannelMap -> HT.TxHash -> ReceiverPaymentChannel -> STM Bool
updateChanState chanMap key chanState =
    updateStoredItem chanMap key (ReadyForPayment chanState)

deleteChanState :: ChannelMap -> HT.TxHash -> HT.TxHash -> STM Bool --TODO: switch to OutPoint key
deleteChanState chanMap key settlementTxId =
    updateStoredItem chanMap key (ChannelSettled settlementTxId)


mapLen = mapGetItemCount

mapGetState :: ChannelMap -> (ChanState -> ChanState) -> HT.TxHash -> STM (Maybe ChanState)
mapGetState m f k  = do
    maybeCS <- getChanState m k
    case maybeCS of
        Nothing -> return Nothing
        Just cs -> updateStoredItem m k (f cs) >> return (Just cs)

-- unsafeUpdatePayment :: ChannelMap -> HT.TxHash -> Payment -> IO


diskSyncThread ::
    (ToFileName k, Serializable v) =>
    DiskMap k v
    -> Int -- ^Sync interval in seconds
    -> IO ()
diskSyncThread m i = putStrLn "Started disk sync thread." >> mapDiskSyncThread m (i * round 1e6)

diskSyncNow ::
    (ToFileName k, Serializable v) =>
    DiskMap k v
    -> IO ()
diskSyncNow = syncToDisk

instance ToFileName HT.OutPoint
instance ToFileName HT.TxHash
instance ToFileName HC.Address

instance Hashable HT.OutPoint where
    hashWithSalt salt (HT.OutPoint h i) =
        salt `hashWithSalt` serialize h `hashWithSalt` i

instance Hashable HT.TxHash where
    hashWithSalt salt txid = hashWithSalt salt (serialize txid)

instance Hashable HC.Address where
    hashWithSalt salt addr = hashWithSalt salt (serialize addr)

instance Serializable HT.OutPoint where
    serialize   = BL.toStrict . Bin.encode
    deserialize = deserEither

instance Serializable HT.TxHash where
    serialize   = BL.toStrict . Bin.encode
    deserialize = deserEither

instance Serializable HC.Address where
    serialize   = HC.addrToBase58
    deserialize bs = maybe
        (Left "couldn't deserialize Address")
        Right
        (HC.base58ToAddr bs)

instance Serializable PaymentChannelState where
    serialize   = BL.toStrict . Bin.encode
    deserialize = deserEither

instance Serializable ChanState where
    serialize   = BL.toStrict . Bin.encode
    deserialize = deserEither

instance Bin.Binary ChanState where
    put (ReadyForPayment s) =
        Bin.putWord8 0x02 >>
        Bin.put s
    put (ChannelSettled txid) =
        Bin.putWord8 0x03 >>
        Bin.put txid
    put (SettlementInProgress s) =
        Bin.putWord8 0x04 >>
        Bin.put s

    get = Bin.getWord8 >>=
        (\byte -> case byte of
            0x02    -> ReadyForPayment   <$> Bin.get
            0x03    -> ChannelSettled   <$> Bin.get
            0x04    -> SettlementInProgress <$> Bin.get
            n       -> fail $ "ChanState parser: unknown start byte: " ++ show n)

