{-# LANGUAGE LambdaCase, OverloadedStrings, ViewPatterns #-}

module Main(main) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import qualified Data.Aeson as J
import qualified Data.Avro as A
import qualified Data.ByteString.Lazy as BL
import qualified Data.DiskHash as DH
import Data.Either
import Data.Maybe
import Data.Monoid
import Data.Proxy
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TL
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.Vector as V
import qualified Database.PostgreSQL.LibPQ as PQ
import qualified Network.HTTP.Client as H
import qualified Network.HTTP.Client.TLS as H
import qualified Options.Applicative as O
import System.IO
import System.IO.Unsafe

import CoinMetrics.BlockChain
import CoinMetrics.Ethereum
import CoinMetrics.Ethereum.ERC20
import Hanalytics.Schema
import Hanalytics.Schema.BigQuery
import Hanalytics.Schema.Postgres

main :: IO ()
main = run =<< O.execParser parser where
	parser = O.info (O.helper <*> opts)
		(  O.fullDesc
		<> O.progDesc "Exports blocks from blockchains into files"
		<> O.header "coinmetrics-export"
		)
	opts = Options
		<$> O.subparser
			(  O.command "export"
				(  O.info
					(O.helper <*> (OptionExportCommand
						<$> O.strOption
							(  O.long "api-url"
							<> O.metavar "API_URL"
							<> O.value ""
							<> O.help "Blockchain API url, like \"http://<host>:<port>/\""
							)
						<*> O.strOption
							(  O.long "blockchain"
							<> O.metavar "BLOCKCHAIN"
							<> O.help "Type of blockchain: ethereum"
							)
						<*> O.option O.auto
							(  O.long "begin-block"
							<> O.metavar "BEGIN_BLOCK"
							<> O.value (-1)
							<> O.help "Begin block number (inclusive)"
							)
						<*> O.option O.auto
							(  O.long "end-block"
							<> O.value 0
							<> O.metavar "END_BLOCK"
							<> O.help "End block number if positive (exclusive), offset to top block if negative, default offset to top block if zero"
							)
						<*> O.switch
							(  O.long "continue"
							<> O.help "Get BEGIN_BLOCK from output, to continue after latest written block. Works with --output-postgres only"
							)
						<*> optionOutput
						<*> O.option O.auto
							(  O.long "threads"
							<> O.value 1 <> O.showDefault
							<> O.metavar "THREADS"
							<> O.help "Threads count"
							)
						<*> O.switch
							(  O.long "ignore-missing-blocks"
							<> O.help "Ignore errors when getting blocks from daemon"
							)
					)) (O.fullDesc <> O.progDesc "Export blockchain")
				)
			<> O.command "print-schema"
				(  O.info
					(O.helper <*> (OptionPrintSchemaCommand
						<$> O.strOption
							(  O.long "schema"
							<> O.metavar "SCHEMA"
							<> O.help "Type of schema: ethereum | erc20tokens"
							)
						<*> O.strOption
							(  O.long "storage"
							<> O.metavar "STORAGE"
							<> O.help "Storage type: postgres | bigquery"
							)
					)) (O.fullDesc <> O.progDesc "Prints schema")
				)
			<> O.command "export-erc20-info"
				(  O.info
					(O.helper <*> (OptionExportERC20InfoCommand
						<$> O.strOption
							(  O.long "input-json-file"
							<> O.metavar "INPUT_JSON_FILE"
							<> O.help "Input JSON file"
							)
						<*> optionOutput
					)) (O.fullDesc <> O.progDesc "Exports ERC20 info")
				)
			)
	optionOutput = Output
		<$> O.option (O.maybeReader (Just . Just))
			(  O.long "output-avro-file"
			<> O.value Nothing
			<> O.metavar "OUTPUT_AVRO_FILE"
			<> O.help "Output Avro file"
			)
		<*> O.option (O.maybeReader (Just . Just))
			(  O.long "output-postgres-file"
			<> O.value Nothing
			<> O.metavar "OUTPUT_POSTGRES_FILE"
			<> O.help "Output PostgreSQL file"
			)
		<*> O.option (O.maybeReader (Just . Just))
			(  O.long "output-postgres"
			<> O.value Nothing
			<> O.metavar "OUTPUT_POSTGRES"
			<> O.help "Output directly to PostgreSQL DB"
			)
		<*> O.option (O.maybeReader (Just . Just))
			(  O.long "output-postgres-table"
			<> O.value Nothing
			<> O.metavar "OUTPUT_POSTGRES_TABLE"
			<> O.help "Table name for PostgreSQL output"
			)
		<*> O.option O.auto
			(  O.long "pack-size"
			<> O.value 100 <> O.showDefault
			<> O.metavar "PACK_SIZE"
			<> O.help "Number of records in pack (SQL INSERT command, or Avro block)"
			)

data Options = Options
	{ options_command :: !OptionCommand
	}

data OptionCommand
	= OptionExportCommand
		{ options_apiUrl :: !String
		, options_blockchain :: !T.Text
		, options_beginBlock :: !BlockHeight
		, options_endBlock :: !BlockHeight
		, options_continue :: !Bool
		, options_outputFile :: !Output
		, options_threadsCount :: !Int
		, options_ignoreMissingBlocks :: !Bool
		}
	| OptionPrintSchemaCommand
		{ options_schema :: !T.Text
		, options_storage :: !T.Text
		}
	| OptionExportERC20InfoCommand
		{ options_inputJsonFile :: !String
		, options_outputFile :: !Output
		}

data Output = Output
	{ output_avroFile :: !(Maybe String)
	, output_postgresFile :: !(Maybe String)
	, output_postgres :: !(Maybe String)
	, output_postgresTable :: !(Maybe String)
	, output_packSize :: !Int
	}

run :: Options -> IO ()
run Options
	{ options_command = command
	} = case command of

	OptionExportCommand
		{ options_apiUrl = apiUrl
		, options_blockchain = blockchainType
		, options_beginBlock = maybeBeginBlock
		, options_endBlock = maybeEndBlock
		, options_continue = continue
		, options_outputFile = outputFile@Output
			{ output_postgres = maybeOutputPostgres
			, output_postgresTable = maybePostgresTable
			}
		, options_threadsCount = threadsCount
		, options_ignoreMissingBlocks = ignoreMissingBlocks
		} -> do
		httpManager <- H.newTlsManagerWith H.tlsManagerSettings
			{ H.managerConnCount = threadsCount * 2
			}
		let withDefaultApiUrl defaultApiUrl = if null apiUrl then defaultApiUrl else apiUrl
		(SomeBlockChain blockChain, defaultBeginBlock, defaultEndBlock) <- case blockchainType of
			"ethereum" -> do
				httpRequest <- H.parseRequest $ withDefaultApiUrl "http://127.0.0.1:8545/"
				return (SomeBlockChain $ newEthereum httpManager httpRequest, 0, -1000) -- very conservative rewrite limit
			_ -> fail "wrong blockchain specified"

		-- get begin block, from output postgres if needed
		beginBlock <- if maybeBeginBlock >= 0 then return maybeBeginBlock else
			if continue
				then case maybeOutputPostgres of
					Just outputPostgres -> do
						connection <- PQ.connectdb $ T.encodeUtf8 $ T.pack outputPostgres
						connectionStatus <- PQ.status connection
						unless (connectionStatus == PQ.ConnectionOk) $ fail $ "postgres connection failed: " <> show connectionStatus
						let query = "SELECT MAX(\"" <> blockHeightFieldName blockChain <> "\") FROM \"" <> maybe blockchainType T.pack maybePostgresTable <> "\""
						result <- maybe (fail "cannot get latest block from postgres") return =<< PQ.execParams connection (T.encodeUtf8 $ query) [] PQ.Text
						resultStatus <- PQ.resultStatus result
						unless (resultStatus == PQ.TuplesOk) $ fail $ "cannot get latest block from postgres: " <> show resultStatus
						tuplesCount <- PQ.ntuples result
						unless (tuplesCount == 1) $ fail "cannot decode tuples from postgres"
						maybeValue <- PQ.getvalue result 0 0
						beginBlock <- case maybeValue of
							Just beginBlockStr -> do
								let maxBlock = read (T.unpack $ T.decodeUtf8 beginBlockStr)
								hPutStrLn stderr $ "got latest block synchronized to postgres: " <> show maxBlock
								return $ maxBlock + 1
							Nothing -> return defaultBeginBlock
						PQ.finish connection
						return beginBlock
					Nothing -> fail "--continue requires --output-postgres"
				else return defaultBeginBlock

		let endBlock = if maybeEndBlock == 0 then defaultEndBlock else maybeEndBlock

		-- simple multithreaded pipeline
		blockIndexQueue <- newTBQueueIO (threadsCount * 2)
		blockIndexQueueEndedVar <- newTVarIO False
		nextBlockIndexVar <- newTVarIO beginBlock
		blockQueue <- newTBQueueIO (threadsCount * 2)

		-- thread adding indices to index queue
		void $ forkIO $
			if endBlock > 0 then do
				mapM_ (atomically . writeTBQueue blockIndexQueue) [beginBlock..(endBlock - 1)]
				atomically $ writeTVar blockIndexQueueEndedVar True
			-- else do infinite stream of indices
			else let
				step i = do
					-- determine current (known) block index
					currentBlockIndex <- getCurrentBlockHeight blockChain
					-- insert indices up to this index minus offset
					let endIndex = currentBlockIndex + endBlock
					hPutStrLn stderr $ "continuously syncing blocks... currently from " <> show i <> " to " <> show (endIndex - 1)
					mapM_ (atomically . writeTBQueue blockIndexQueue) [i..(endIndex - 1)]
					-- pause
					threadDelay 10000000
					-- repeat
					step endIndex
				in step beginBlock

		-- work threads getting blocks from blockchain
		forM_ [1..threadsCount] $ \_ -> let
			step = do
				maybeBlockIndex <- atomically $ do
					maybeBlockIndex <- tryReadTBQueue blockIndexQueue
					case maybeBlockIndex of
						Just _ -> return maybeBlockIndex
						Nothing -> do
							blockIndexQueueEnded <- readTVar blockIndexQueueEndedVar
							if blockIndexQueueEnded
								then return Nothing
								else retry
				case maybeBlockIndex of
					Just blockIndex -> do
						-- get block from blockchain
						eitherBlock <- try $ getBlockByHeight blockChain blockIndex
						case eitherBlock of
							Right block ->
								-- insert block into block queue ensuring order
								atomically $ do
									nextBlockIndex <- readTVar nextBlockIndexVar
									if blockIndex == nextBlockIndex then do
										writeTBQueue blockQueue (blockIndex, block)
										writeTVar nextBlockIndexVar (nextBlockIndex + 1)
									else retry
							Left (SomeException err) -> do
								print err
								-- if it's allowed to ignore errors, do that
								if ignoreMissingBlocks
									then atomically $ do
										nextBlockIndex <- readTVar nextBlockIndexVar
										if blockIndex == nextBlockIndex
											then writeTVar nextBlockIndexVar (nextBlockIndex + 1)
											else retry
									-- otherwise rethrow error
									else throwIO err
						-- repeat
						step
					Nothing -> return ()
			in forkIO step

		-- write blocks into outputs, using lazy IO
		let step i = if endBlock <= 0 || i < endBlock
			then unsafeInterleaveIO $ do
				(blockIndex, block) <- atomically $ readTBQueue blockQueue
				when (blockIndex `rem` 100 == 0) $ hPutStrLn stderr $ "synced up to " ++ show blockIndex
				(block :) <$> step (blockIndex + 1)
			else return []
		writeOutput outputFile blockchainType =<< step beginBlock
		hPutStrLn stderr $ "sync from " ++ show beginBlock ++ " to " ++ show (endBlock - 1) ++ " complete"

	OptionPrintSchemaCommand
		{ options_schema = schemaTypeStr
		, options_storage = storageTypeStr
		} -> case (schemaTypeStr, storageTypeStr) of
		("ethereum", "postgres") -> do
			putStr $ T.unpack $ TL.toStrict $ TL.toLazyText $ mconcat $ map postgresSqlCreateType
				[ schemaOf (Proxy :: Proxy EthereumLog)
				, schemaOf (Proxy :: Proxy EthereumTransaction)
				, schemaOf (Proxy :: Proxy EthereumUncleBlock)
				, schemaOf (Proxy :: Proxy EthereumBlock)
				]
			putStrLn $ T.unpack $ "CREATE TABLE \"ethereum\" OF \"EthereumBlock\" (PRIMARY KEY (\"number\"));"
		("ethereum", "bigquery") ->
			putStrLn $ T.unpack $ T.decodeUtf8 $ BL.toStrict $ J.encode $ bigQuerySchema $ schemaOf (Proxy :: Proxy EthereumBlock)
		("erc20tokens", "postgres") ->
			putStrLn $ T.unpack $ TL.toStrict $ TL.toLazyText $ "CREATE TABLE erc20tokens (" <> concatFields (postgresSchemaFields True $ schemaOf (Proxy :: Proxy ERC20Info)) <> ");"
		("erc20tokens", "bigquery") ->
			putStrLn $ T.unpack $ T.decodeUtf8 $ BL.toStrict $ J.encode $ bigQuerySchema $ schemaOf (Proxy :: Proxy ERC20Info)

	OptionExportERC20InfoCommand
		{ options_inputJsonFile = inputJsonFile
		, options_outputFile = outputFile
		} -> do
		tokensInfos <- either fail return . J.eitherDecode' =<< BL.readFile inputJsonFile
		writeOutput outputFile "erc20tokens" (tokensInfos :: [ERC20Info])

	where
		blockSplit :: Int -> [a] -> [[a]]
		blockSplit packSize = \case
			[] -> []
			xs -> let (a, b) = splitAt packSize xs in a : blockSplit packSize b

		writeOutput :: (A.ToAvro a, ToPostgresText a) => Output -> T.Text -> [a] -> IO ()
		writeOutput Output
			{ output_avroFile = maybeOutputAvroFile
			, output_postgresFile = maybeOutputPostgresFile
			, output_postgres = maybeOutputPostgres
			, output_postgresTable = maybePostgresTable
			, output_packSize = packSize
			} defaultTableName (blockSplit packSize -> blocks) = do
			vars <- forM outputs $ \output -> do
				var <- newTVarIO Nothing
				void $ forkFinally output $ atomically . writeTVar var . Just
				return var
			results <- atomically $ do
				results <- mapM readTVar vars
				unless (all isJust results || any (maybe False isLeft) results) retry
				return results
			let erroredResults = concat $ map (maybe [] (either pure (const []))) results
			unless (null erroredResults) $ do
				print erroredResults
				fail "output failed"

			where outputs = let tableName = fromMaybe defaultTableName $ T.pack <$> maybePostgresTable in concat
				[ case maybeOutputAvroFile of
					Just outputAvroFile -> [BL.writeFile outputAvroFile =<< A.encodeContainer blocks]
					Nothing -> []
				, case maybeOutputPostgresFile of
					Just outputPostgresFile -> [BL.writeFile outputPostgresFile $ TL.encodeUtf8 $ TL.toLazyText $ mconcat $ map (postgresSqlInsertGroup tableName) blocks]
					Nothing -> []
				, case maybeOutputPostgres of
					Just outputPostgres ->
						[ do
							connection <- PQ.connectdb $ T.encodeUtf8 $ T.pack outputPostgres
							connectionStatus <- PQ.status connection
							unless (connectionStatus == PQ.ConnectionOk) $ fail $ "postgres connection failed: " <> show connectionStatus
							forM_ blocks $ \block -> do
								resultStatus <- maybe (return PQ.FatalError) PQ.resultStatus <=< PQ.exec connection $ T.encodeUtf8 $ TL.toStrict $ TL.toLazyText $ postgresSqlInsertGroup tableName block
								unless (resultStatus == PQ.CommandOk) $ fail $ "command failed: " <> show resultStatus
							PQ.finish connection
							]
					Nothing -> []
				]

		concatFields = foldr1 $ \a b -> a <> ", " <> b
