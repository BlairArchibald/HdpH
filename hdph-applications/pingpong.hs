{-# LANGUAGE TemplateHaskell #-}

module Main where

import System.IO
import System.Environment

import System.Clock

import Data.Monoid

import Control.Monad
import Control.Applicative ((<$>))

import Control.Parallel.HdpH
import Control.Parallel.HdpH as HdpH (declareStatic)


instance ToClosure () where locToClosure = $(here)

latencyTest :: Int -> Int -> Par ()
latencyTest npings ntimes = do
  w <- allNodes

  io $ putStrLn $ "From To Min Mean Max"

  forM_ w $ \n -> do
    done <- new
    ret  <- glob done
    pushTo $(mkClosure [|ping (npings, ntimes, ret)|]) n
    get done

message :: GIVar (Closure ()) -> Thunk (Par ())
message ivar = Thunk $ rput ivar $ toClosure ()

ping :: (Int, Int, GIVar (Closure ())) -> Thunk (Par ())
ping (npings, ntimes, done) = Thunk $ do
  m  <- myNode
  ns <- allNodes

  forM_ ns $ \n -> do
      ts <- replicateM ntimes $ do
                start <- io $ getTime Monotonic
                replicateM npings $ do
                    i   <- new
                    ret <- glob i
                    -- Note: we block in the loop (get) so that we only talk to one node at a time.
                    pushTo $(mkClosure [|message ret|]) n >> get i
                end  <- io $ getTime Monotonic
                return $ timeDiffMSecs start end
      io $ analyseAndPrintResults m n ts

  rput done $ toClosure () --Singal that we have pinged every node.

analyseAndPrintResults :: Node -> Node -> [Double] -> IO ()
analyseAndPrintResults from to res = do
  let mn   = foldr min (head res) res
      mean = sum res / fromIntegral (length res)
      mx   = foldr max (head res) res
  putStrLn $ (show from) ++ " " ++ (show to) ++ " " ++ (show mn) ++ "ms " ++ (show mean) ++ "ms " ++ (show mx) ++ "ms"

timeDiffUSecs :: TimeSpec -> TimeSpec -> Double
timeDiffUSecs (TimeSpec s1 n1) (TimeSpec s2 n2) = fromIntegral (t2 - t1) / fromIntegral (10 ^ 3)
  where t1 = (fromIntegral s1 * 10 ^ 9) + fromIntegral n1
        t2 = (fromIntegral s2 * 10 ^ 9) + fromIntegral n2

timeDiffMSecs :: TimeSpec -> TimeSpec -> Double
timeDiffMSecs (TimeSpec s1 n1) (TimeSpec s2 n2) = fromIntegral (t2 - t1) / fromIntegral (10 ^ 6)
  where t1 = (fromIntegral s1 * 10 ^ 9) + fromIntegral n1
        t2 = (fromIntegral s2 * 10 ^ 9) + fromIntegral n2

$(return [])
staticDecls :: StaticDecl
staticDecls = mconcat [HdpH.declareStatic,
                       declare (staticToClosure :: StaticToClosure ()),
                       declare $(static 'message),
                       declare $(static 'ping)]


main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  register staticDecls -- register the static table so we can distribute it
  (rtsConf, args') <- parseOpts =<< getArgs
  let times = case args' of
                nPings:nTimes:[] -> (read nPings, read nTimes)
                _         -> (100,100)
  runParIO_ rtsConf $ uncurry latencyTest times

parseOpts :: [String] -> IO (RTSConf, [String])
parseOpts args = do
  either_conf <- updateConf args defaultRTSConf
  case either_conf of
    Left err_msg                 -> error $ "parseOpts: " ++ err_msg
    Right (conf, remaining_args) -> return (conf, remaining_args)
