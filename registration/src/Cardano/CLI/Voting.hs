{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Performs the bulk of the work creating the vote registration
-- transaction.

module Cardano.CLI.Voting where

import           Control.Lens (( # ))
import           Data.Maybe (fromMaybe)
import           Control.Monad.Except (MonadError, throwError)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BSC
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import           Data.String (fromString)
import           Data.Text (Text)

import           Cardano.API (ShelleyEra, IsShelleyBasedEra, Address, AddressInEra(AddressInEra), AsType (AsPaymentKey, AsStakeKey), Key, LocalNodeConnectInfo,
                     Lovelace, NetworkId, PaymentCredential, PaymentKey, SigningKey,
                     StakeAddressReference, StakeCredential, StakeKey, Tx, TxBody, SlotNo,
                     TxIn (TxIn), TxMetadata, VerificationKey, ShelleyBasedEra, castVerificationKey,
                     anyAddressInShelleyBasedEra, deserialiseFromRawBytesHex, estimateTransactionFee, getVerificationKey,
                     localNodeNetworkId, makeShelleyAddress, makeShelleyKeyWitness,
                     makeSignedTransaction, makeTransactionMetadata,
                     serialiseToBech32, serialiseToRawBytes, serialiseToRawBytesHex,
                     verificationKeyHash, AddressAny)
import           Cardano.Api.LocalChainSync (getLocalTip)
import           Cardano.Api.Typed (AsType (AsSigningKey), Lovelace(Lovelace),
                     PaymentCredential (PaymentCredentialByKey), Shelley,
                     StandardAllegra, ShelleyWitnessSigningKey (WitnessPaymentKey), SigningKey (StakeSigningKey),
                     StakeAddressReference (StakeAddressByValue),
                     StakeCredential (StakeCredentialByKey), StandardShelley, TxId (TxId),
                     TxIx (TxIx),
                     TxMetadataValue (TxMetaBytes, TxMetaMap, TxMetaNumber, TxMetaText),
                     TxOut (TxOut), VerificationKey (StakeVerificationKey),
                     deterministicSigningKey, deterministicSigningKeySeedSize, txCertificates,
                     txMetadata, txUpdateProposal, txWithdrawals)
import qualified Cardano.Binary as CBOR
import           Cardano.CLI.Types (QueryFilter (FilterByAddress, NoFilter))
import           Cardano.Crypto.DSIGN.Class
import qualified Cardano.Crypto.DSIGN.Class as Crypto
import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Seed as Crypto
import qualified Codec.Binary.Bech32 as Bech32
import           Ouroboros.Consensus.Cardano.Block (Query)
import           Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr, GenTx)
import           Ouroboros.Consensus.Shelley.Protocol.Crypto (StandardCrypto)
import           Ouroboros.Network.Block (getTipSlotNo)
import           Ouroboros.Network.Point (fromWithOrigin)
import           Ouroboros.Network.Protocol.LocalStateQuery.Type (ShowQuery)
import           Ouroboros.Network.Util.ShowProxy (ShowProxy)
import qualified Shelley.Spec.Ledger.Coin as Ledger
import qualified Shelley.Spec.Ledger.Keys as Shelley
import           Shelley.Spec.Ledger.PParams (PParams)
import qualified Shelley.Spec.Ledger.PParams as Shelley
import qualified Shelley.Spec.Ledger.Tx as Ledger
import qualified Shelley.Spec.Ledger.UTxO as Ledger
import           Cardano.Ledger.Crypto (Crypto (..))

import           Cardano.API.Extended (textEnvelopeToJSON)
import           Cardano.API.Extended (AsBech32DecodeError, AsBech32HumanReadablePartError,
                     AsShelleyQueryCmdLocalStateQueryError, AsType (AsVotingKeyPublic),
                     VotingKeyPublic, deserialiseFromBech32', queryPParamsFromLocalState,
                     queryUTxOFromLocalState)
import           Cardano.CLI.Voting.Error
import           Cardano.CLI.Voting.Fee
import           Cardano.CLI.Voting.Metadata (Vote, VotePayload, mkVotePayload, signVotePayload, voteToTxMetadata)
import           Cardano.CLI.Voting.Signing (VoteSigningKey, withVoteShelleySigningKey,
                     withVoteSigningKey)
import           Cardano.CLI.Voting.Signing (sign, verify, getVoteVerificationKey)

-- | Create a vote registration payload.
createVote
  :: VoteSigningKey
  -> VotingKeyPublic
  -> Vote
createVote skey votepub =
    let
      payload     = mkVotePayload votepub (getVoteVerificationKey skey)
      payloadCBOR = CBOR.serialize' payload

      payloadSig  :: SigDSIGN (DSIGN StandardCrypto)
      payloadSig  = payloadCBOR `sign` skey
  in
    fromMaybe (error "Failed to sign vote payload") $
      signVotePayload payload payloadSig

-- | Encode the vote registration payload as a transaction body.
encodeVote
  :: ( MonadIO m
     , MonadError e m
     , AsShelleyQueryCmdLocalStateQueryError e
     , AsNotEnoughFundsError e

     , ShowProxy block
     , ShowProxy (ApplyTxErr block)
     , ShowProxy (Query block)
     , ShowProxy (GenTx block)
     , ShowQuery (Query block)
     )
  => LocalNodeConnectInfo mode block
  -> ShelleyEra
  -> AddressAny
  -> SlotNo
  -> Vote
  -> m (TxBody Shelley)
encodeVote connectInfo era addr ttl vote = do
  let
    addrShelley :: IsShelleyBasedEra era => AddressInEra era
    addrShelley = anyAddressInShelleyBasedEra addr
  -- Get the network parameters
  pparams <- queryPParamsFromLocalState connectInfo
  let
    meta      = voteToTxMetadata vote
    networkId = localNodeNetworkId connectInfo

  -- Estimate the fee for the transaction
  let
    feeParams = estimateVoteFeeParams networkId era pparams meta

  -- Find some unspent funds
  utxos  <- queryUTxOFromLocalState era (FilterByAddress $ Set.singleton addr) connectInfo
  case findUnspent feeParams (fromShelleyUTxO utxos) of
    Nothing      -> throwError $ _NotEnoughFundsToMeetFeeError # (fromShelleyUTxO utxos)
    Just unspent -> do
      tip <- liftIO $ getLocalTip connectInfo
      let
        slotTip          = fromWithOrigin minBound $ getTipSlotNo tip
        txins            = unspentSources unspent
        (Lovelace value) = unspentValue unspent
        (Lovelace fee)   =
          estimateVoteTxFee
            networkId era pparams slotTip txins addrShelley (Lovelace value) meta

      undefined
--       -- Create the vote transaction
--       pure $ voteTx addrShelley txins (Lovelace $ value - fee) (slotTip + ttl) (Lovelace fee) meta

-- -- | Helper for creating a transaction body.
-- voteTx
--   :: AddressInEra era
--   -> [TxIn]
--   -> Lovelace
--   -> SlotNo
--   -> Lovelace
--   -> TxMetadata
--   -> TxBody Shelley
-- voteTx addr txins (Lovelace value) ttl (Lovelace fee) meta =
--  let
--    txouts = [TxOut addr (Lovelace value)]
--  in
--    makeShelleyTransaction txExtraContentEmpty {
--                             txCertificates   = [],
--                             txWithdrawals    = [],
--                             txMetadata       = Just meta,
--                             txUpdateProposal = Nothing
--                           }
--                           ttl
--                           (Lovelace fee)
--                           txins
--                           txouts

-- | Sign a transaction body to create a transaction.
signTx :: SigningKey PaymentKey -> TxBody Shelley -> Tx Shelley
signTx psk txbody =
  let
    witness = makeShelleyKeyWitness txbody (WitnessPaymentKey psk)
  in
    makeSignedTransaction [witness] txbody

-- | Pretty print a transaction.
prettyTx :: Tx Shelley -> String
prettyTx = BSC.unpack . textEnvelopeToJSON Nothing

fromShelleyUTxO :: Ledger.UTxO StandardShelley -> UnspentSources
fromShelleyUTxO = fmap convert . M.assocs . Ledger.unUTxO
  where
    convert :: (Ledger.TxIn StandardShelley, Ledger.TxOut StandardShelley) -> (TxIn, Lovelace)
    convert (txin, Ledger.TxOut _ (Ledger.Coin value)) = (fromShelleyTxIn txin, Lovelace value)

fromShelleyTxIn  :: Ledger.TxIn StandardShelley -> TxIn
fromShelleyTxIn (Ledger.TxIn txid txix) =
    TxIn (fromShelleyTxId txid) (TxIx (fromIntegral txix))

fromShelleyTxId :: Ledger.TxId StandardShelley -> TxId
fromShelleyTxId (Ledger.TxId h) =
    TxId (Crypto.castHash h)
