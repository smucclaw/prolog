{-# LANGUAGE ViewPatterns, GeneralizedNewtypeDeriving, FlexibleInstances, FlexibleContexts, UndecidableInstances, IncoherentInstances #-}
module Interpreter
   ( resolve, resolve_
   , MonadTrace(..), withTrace
   , MonadGraphGen(..), runNoGraphT
   )
where
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State
import Control.Monad.Except
import Control.Monad.Fix
import Data.Maybe (isJust)
import Data.Generics (everywhere, mkT)
import Control.Applicative ((<$>),(<*>),(<$),(<*), Applicative(..), Alternative)
import Data.List (sort, nub)

import Syntax
import Unifier
import Database


builtins :: [Clause]
builtins =
   [ Clause (Struct "="   [var "X", var "X"]) []
   , Clause (Struct "\\=" [var "X", var "X"]) [cut, Struct "false" []]
   , Clause (Struct "\\=" [var "X", var "Y"]) []
   , Clause (Struct "not" [var "A"]) [var "A", cut, Struct "false" []]
   , Clause (Struct "not" [var "A"]) []
   , Clause (Struct "\\+" [var "A"]) [var "A", cut, Struct "false" []]
   , Clause (Struct "\\+" [var "A"]) []
   , Clause (Struct "true" []) []
   , Clause (Struct "," [var "A", var "B"]) [var "A", var "B"]
   , Clause (Struct ";" [var "A", Wildcard]) [var "A"]
   , Clause (Struct ";" [Wildcard, var "B"]) [var "B"]
   , ClauseFn (Struct "is"  [var "L", var "R"]) is
   , ClauseFn (Struct "<"   [var "N", var "M"]) (binaryIntegerPredicate (<))
   , ClauseFn (Struct ">"   [var "N", var "M"]) (binaryIntegerPredicate (>))
   , ClauseFn (Struct "=<"  [var "N", var "M"]) (binaryIntegerPredicate (<=))
   , ClauseFn (Struct ">="  [var "N", var "M"]) (binaryIntegerPredicate (>=))
   , ClauseFn (Struct "=:=" [var "N", var "M"]) (binaryIntegerPredicate (==))
   , ClauseFn (Struct "@<" [var "T1", var "T2"]) (binaryPredicate (<))
   , ClauseFn (Struct "@>" [var "T1", var "T2"]) (binaryPredicate (>))
   , ClauseFn (Struct "@=<"[var "T1", var "T2"]) (binaryPredicate (<=))
   , ClauseFn (Struct "@>="[var "T1", var "T2"]) (binaryPredicate (>=))
   , ClauseFn (Struct "==" [var "T1", var "T2"]) (binaryPredicate (==))
   , ClauseFn (Struct "sort" [var "Input", var "Output"]) (function sort_pl)
   , ClauseFn (Struct "=.." [var "Term", var "List"]) univ
   , ClauseFn (Struct "atom" [var "T"]) atom
   , ClauseFn (Struct "char_code" [var "Atom", var "Code"]) char_code
   , Clause (Struct "phrase" [var "RuleName", var "InputList"])
               [Struct "phrase" [var "RuleName", var "InputList", Struct "[]" []]]
   , Clause (Struct "phrase" [var "Rule", var "InputList", var "Rest"])
               [ Struct "=.." [var "Rule", var "L"]
               , Struct "append" [var "L", foldr cons nil (arguments [{- already in L -}] (var "InputList") (var "Rest")), var "L1"] -- FIXME This makes assumptions about "arguments"
               , Struct "=.." [var "Goal", var "L1"]
               , var "Goal"
               ]
   ]
 where
   binaryIntegerPredicate :: (Integer -> Integer -> Bool) -> ([Term] -> [Goal])
   binaryIntegerPredicate p [eval->Just n, eval->Just m] | n `p` m = []
   binaryIntegerPredicate p _ = [Struct "false" []]

   binaryPredicate :: (Term -> Term -> Bool) -> ([Term] -> [Goal])
   binaryPredicate p [t1, t2] | t1 `p` t2 = []
   binaryPredicate p _ = [Struct "false" []]

   is [t, eval->Just n] = [Struct "=" [t, Struct (show n) []]]
   is _                 = [Struct "false" []]

   eval (Struct (reads->[(n,"")]) []) = return n :: Maybe Integer
   eval (Struct "+" [t1, t2])   = (+) <$> eval t1 <*> eval t2
   eval (Struct "*" [t1, t2])   = (*) <$> eval t1 <*> eval t2
   eval (Struct "-" [t1, t2])   = (-) <$> eval t1 <*> eval t2
   eval (Struct "mod" [t1, t2]) = mod <$> eval t1 <*> eval t2
   eval (Struct "div" [t1, t2]) = div <$> eval t1 <*> eval t2
   eval (Struct "-" [t])        = negate <$> eval t
   eval _                       = mzero

   univ [Struct a ts, list]                        = [Struct "=" [Struct "." [Struct a [], foldr cons nil ts], list]]
   univ [term,        Struct "." [Struct a [], t]] = [Struct "=" [term, Struct a (foldr_pl (:) [] t)]]
   univ _                                          = [Struct "false" []]

   atom [Struct _ []] = []
   atom _             = [Struct "false" []]

   char_code [Struct [c] [], t]               = [Struct "=" [Struct (show (fromEnum c)) [], t]]
   char_code [t, Struct (reads->[(n,"")]) []] = [Struct "=" [t, Struct [toEnum n] []]]
   char_code _                                = [Struct "false" []]

   function :: (Term -> Term) -> ([Term] -> [Goal])
   function f [input, output] = [Struct "=" [output, f input]]

   sort_pl = foldr cons nil . nub . sort . foldr_pl (:) []

class Monad m => MonadTrace m where
   trace :: String -> m ()
instance MonadTrace (Trace IO) where
   trace = Trace . putStrLn
instance MonadTrace IO where
   trace _ = return ()
instance MonadTrace (Either err) where
   trace _ = return ()
instance (MonadTrace m, MonadTrans t, Monad (t m)) => MonadTrace (t m) where
   trace x = lift (trace x)


newtype Trace m a = Trace { withTrace :: m a }  deriving (Functor, Applicative, Monad, MonadError e)

trace_ label x = trace (label++":\t"++show x)


class Monad m => MonadGraphGen m where
   createConnections :: Branch -> [Branch] -> [Branch] -> m ()
   markSolution :: Unifier -> m ()
   markCutBranches :: Stack -> m ()

instance MonadGraphGen m => MonadGraphGen (ReaderT r m) where
   createConnections x y z = lift (createConnections x y z)
   markSolution = lift . markSolution
   markCutBranches = lift . markCutBranches


newtype NoGraphT m a = NoGraphT {runNoGraphT :: m a} deriving (Monad, Functor, MonadFix, Alternative, MonadPlus, Applicative, MonadError e)
instance MonadTrans NoGraphT where
   lift = NoGraphT

instance Monad m => MonadGraphGen (NoGraphT m) where
   createConnections _ _ _ = NoGraphT $ return ()
   markSolution      _      = NoGraphT $ return ()
   markCutBranches   _      = NoGraphT $ return ()


type Stack = [(Branch, [Branch])]
type Branch = (Path, Unifier, [Goal])
type Path = [Integer] -- Used for generating graph output
root = [] :: Path

resolve :: (Functor m, MonadTrace m, MonadError String m) => Program -> [Goal] -> m [Unifier]
resolve program goals = runNoGraphT (resolve_ program goals)

resolve_ :: (Functor m, MonadTrace m, MonadError String m, MonadGraphGen m) => Program -> [Goal] -> m [Unifier]
-- Yield all unifiers that resolve <goal> using the clauses from <program>.
resolve_ program goals = map cleanup <$> runReaderT (resolve' 1 (root, [], goals) []) (createDB (builtins ++ program) ["false","fail"])   -- NOTE Is it a good idea to "hardcode" the builtins like this?
  where
      cleanup = filter ((\(VariableName i _) -> i == 0) . fst)

      whenPredicateIsUnknown sig action = asks (hasPredicate sig) >>= flip unless action

      --resolve' :: Int -> Unifier -> [Goal] -> Stack -> m [Unifier]
      resolve' depth (path, usf, []) stack = do
         trace "=== yield solution ==="
         trace_ "Depth" depth
         trace_ "Unif." usf

         markSolution usf

         (cleanup usf:) <$> backtrack depth stack
      resolve' depth (path, usf, Cut n:gs) stack = do
         trace "=== resolve' (Cut) ==="
         trace_ "Depth"   depth
         trace_ "Unif."   usf
         trace_ "Goals"   (Cut n:gs)
         mapM_ (trace_ "Stack") stack

         createConnections (path, usf, Cut n:gs) [(1:path,[],[])] [(1:path, usf, gs)]

         markCutBranches (take n stack)

         resolve' depth (1:path, usf, gs) (drop n stack)
      resolve' depth (path, usf, goals@(Struct "asserta" [fact]:gs)) stack = do
         trace "=== resolve' (asserta/1) ==="
         trace_ "Depth"   depth
         trace_ "Unif."   usf
         trace_ "Goals"   goals
         mapM_ (trace_ "Stack") stack

         createConnections (path, usf, goals) [(1:path,[],[])] [(1:path, usf, gs)]

         local (asserta fact) $ resolve' depth (1:path, usf, gs) stack
      resolve' depth (path, usf, goals@(Struct "assertz" [fact]:gs)) stack = do
         trace "=== resolve' (assertz/1) ==="
         trace_ "Depth"   depth
         trace_ "Unif."   usf
         trace_ "Goals"   goals
         mapM_ (trace_ "Stack") stack

         createConnections (path, usf, goals) [(1:path,[],[])] [(1:path, usf, gs)]

         local (assertz fact) $ resolve' depth (1:path, usf, gs) stack
      resolve' depth (path, usf, goals@(Struct "retract" [t]:gs)) stack = do
         trace "=== resolve' (retract/1) ==="
         trace_ "Depth"   depth
         trace_ "Unif."   usf
         trace_ "Goals"   goals
         mapM_ (trace_ "Stack") stack

         createConnections (path, usf, goals) [(1:path,[],[])] [(1:path, usf, gs)]

         clauses <- asks (getClauses t)
         case [ t' | Clause t' [] <- clauses, isJust (unify t t') ] of
            []       -> return (fail "retract/1")
            (fact:_) -> local (abolish fact) $ resolve' depth (1:path, usf, gs) stack
      resolve' depth (path, usf, goals@(nextGoal@(Struct "=" [l,r]):gs)) stack = do
         -- This special case is here to avoid introducing unnecessary
         -- variables that occur when applying "X=X." as a rule.
         trace "=== resolve' (=/2) ==="
         trace_ "Depth"   depth
         trace_ "Unif."   usf
         trace_ "Goals"   goals
         mapM_ (trace_ "Stack") stack

         let bs = [ (1:path,u,[]) | u <- unify l r ]
         let branches = do
             (p,u,[]) <- bs
             let u'  = usf +++ u
                 gs' = map (apply u') gs
                 gs'' = everywhere (mkT shiftCut) gs'
             return (p, u', gs'')

         createConnections (path, usf, nextGoal:gs) bs branches

         choose depth (path,usf,gs) branches stack

        where
         shiftCut (Cut n) = Cut (succ n)
         shiftCut t       = t
      resolve' depth (path, usf, nextGoal:gs) stack = do
         trace "=== resolve' ==="
         trace_ "Depth"   depth
         trace_ "Unif."   usf
         trace_ "Goals"   (nextGoal:gs)
         mapM_ (trace_ "Stack") stack
         let sig = signature nextGoal
         whenPredicateIsUnknown sig $ do
            throwError $ "Unknown predicate: " ++ show sig
         bs <- getProtoBranches -- Branch generation happens in two phases so visualizers can pick what to display.
         let branches = do
               (p, u, newGoals) <- bs
               let u' = usf +++ u
               let gs'  = map (apply u') $ newGoals ++ gs
               let gs'' = everywhere (mkT shiftCut) gs'
               return (p, u', gs'')

         createConnections (path, usf, nextGoal:gs) bs branches

         choose depth (path,usf,gs) branches stack
       where
         getProtoBranches = do
            clauses <- asks (getClauses nextGoal)
            return $ do
               (i,clause) <- zip [1..] $ renameVars clauses
               u <- unify (apply usf nextGoal) (lhs clause)
               return (i:path, u, rhs clause (map snd u))


         shiftCut (Cut n) = Cut (succ n)
         shiftCut t       = t

         renameVars = everywhere $ mkT $ \(VariableName _ v) -> VariableName depth v

      choose depth _           []              stack = backtrack depth stack
      choose depth (path,u,gs) ((path',u',gs'):alts) stack = do
         trace "=== choose ==="
         trace_ "Depth"   depth
         trace_ "Unif."   u
         trace_ "Goals"   gs
         mapM_ (trace_ "Alt.") ((path',u',gs'):alts)
         mapM_ (trace_ "Stack") stack
         resolve' (succ depth) (path',u',gs') (((path,u,gs),alts) : stack)

      backtrack _     [] = do
         trace "=== give up ==="
         return (fail "Goal cannot be resolved!")
      backtrack depth (((path,u,gs),alts):stack) = do
         trace "=== backtrack ==="
         choose (pred depth) (path,u,gs) alts stack


