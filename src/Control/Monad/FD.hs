{-# LANGUAGE
    DataKinds
  , EmptyDataDecls
  , KindSignatures
  , Rank2Types
  , RecordWildCards #-}
module Control.Monad.FD
       ( FD
       , runFD
       , FDT
       , runFDT
       , Var
       , freshVar
       , Term (..)
       , Range (..)
       , Indexical (..)
       , tell
       , label
       ) where

import Control.Applicative
import Control.Monad (MonadPlus (mplus, mzero),
                      liftM,
                      liftM2,
                      msum,
                      unless,
                      when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Logic (LogicT, observeAllT)
import Control.Monad.Trans.State (StateT, evalStateT)
import qualified Control.Monad.Trans.State as State
import Control.Monad.Trans.Class (MonadTrans (lift))

import Data.Foldable (forM_, toList)
import Data.Function (on)
import Data.Functor.Identity
import Data.Hashable
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.Monoid
import Data.Tuple (swap)

import Prelude hiding (max, min)

import Control.Monad.FD.DList (DList)
import qualified Control.Monad.FD.DList as DList
import Control.Monad.FD.Dom (Dom)
import qualified Control.Monad.FD.Dom as Dom
import Control.Monad.FD.HashMap.Lazy (HashMap, (!))
import qualified Control.Monad.FD.HashMap.Lazy as HashMap
import Control.Monad.FD.Int
import Control.Monad.FD.Pruning (Pruning, affectedBy)
import qualified Control.Monad.FD.Pruning as Pruning

type FD s = FDT s Identity

runFD :: (forall s . FD s a) -> [a]
runFD = runIdentity . runFDT

newtype FDT s m a =
  FDT { unFDT :: StateT (S s m) (LogicT m) a
      }

runFDT :: Monad m => (forall s . FDT s m a) -> m [a]
runFDT m = observeAllT . flip evalStateT initS $ unFDT m

instance Functor m => Functor (FDT s m) where
  fmap f = FDT . fmap f . unFDT

instance Applicative m => Applicative (FDT s m) where
  pure = FDT . pure
  f <*> a = FDT $ unFDT f <*> unFDT a

instance Applicative m => Alternative (FDT s m) where
  empty = FDT empty
  m <|> n = FDT $ unFDT m <|> unFDT n

instance Monad m => Monad (FDT s m) where
  return = FDT . return
  m >>= k = FDT $ unFDT m >>= (unFDT . k)
  m >> n = FDT $ unFDT m >> unFDT n
  fail = FDT . fail

instance Monad m => MonadPlus (FDT s m) where
  mzero = FDT mzero
  mplus m n = FDT $ mplus (unFDT m) (unFDT n)

instance MonadTrans (FDT s) where
  lift = FDT . lift . lift

instance MonadIO m => MonadIO (FDT s m) where
  liftIO = lift . liftIO

newtype Var (s :: Region) = Var { unwrapVar :: Integer } deriving Eq

instance Hashable (Var s) where
  hash = hash . unwrapVar
  hashWithSalt salt = hashWithSalt salt . unwrapVar

freshVar :: Monad m => FDT s m (Var s)
freshVar = do
  s@S {..} <- get
  let x = Var varCount
  put s { varCount = varCount + 1
        , vars = HashMap.insert x initVarS vars
        }
  return x

infixl 6 :+, :-
infixl 7 :*, `Quot`, `Div`
data Term s
  = Term s :+ Term s
  | Term s :- Term s
  | Int :* Term s
  | Term s `Quot` Int
  | Term s `Div` Int
  | Int Int
  | Min (Var s)
  | Max (Var s)

infix 5 :..
data Range s
  = Term s :.. Term s
  | Dom (Var s)

infixr 1 `In`
data Indexical s = Var s `In` Range s

tell :: Monad m => [Indexical s] -> FDT s m ()
tell is = do
  entailed <- newFlag
  forM_ is $ \ (x `In` r) -> do
    (m, a) <- getConditionalRangeVars r
    case (HashSet.null m, HashSet.null a) of
      (True, antimonotone) ->
        readDomain x >>= pruneDom r >>= maybe
        (unless antimonotone $ addPropagator x r m a entailed)
        (\ (d, pruning) -> do
            when (Dom.null d) mzero
            addPropagator x r m a entailed
            writeDomain x d
            dispatchPruning x pruning)
      (False, True) ->
        readDomain x >>= pruneDom r >>=
        flip whenNothing (addPropagator x r m a entailed)
      (False, False) ->
        addPropagator x r m a entailed

addPropagator :: Monad m =>
                 Var s -> Range s ->
                 MonotoneVars s -> AntimonotoneVars s ->
                 Flag s ->
                 FDT s m ()
addPropagator x r m a entailed = do
  propagator <- newPropagator m a
  forM_ m $ \ x' ->
    addListener x' $ \ pruning ->
      when (Pruning.val `affectedBy` pruning) $
        modifyMonotoneVars propagator $ HashSet.delete x'
  forM_ a $ \ x' ->
    addListener x' $ \ pruning ->
      when (Pruning.val `affectedBy` pruning) $
        modifyAntimonotoneVars propagator $ HashSet.delete x'
  HashMap.forWithKeyM_ (rangeVars r) $ \ x' dependentPruning ->
    addListener x' $ \ pruning ->
      when (dependentPruning `affectedBy` pruning) $
        unlessMarked entailed $ do
          PropagatorS {..} <- readPropagator propagator
          case (HashSet.null monotoneVars, HashSet.null antimonotoneVars) of
            (True, antimonotone) ->
              readDomain x >>= pruneDom r >>= maybe
              (when antimonotone $ mark entailed)
              (\ (d, pruning') -> do
                  when (Dom.null d) mzero
                  writeDomain x d
                  dispatchPruning x pruning')
            (False, True) ->
              readDomain x >>= pruneDom r >>=
              flip whenNothing (mark entailed)
            (False, False) ->
              return ()

label :: Monad m => Var s -> FDT s m Int
label x = do
  d <- readDomain x
  case Dom.toList d of
    [i] -> return i
    is -> msum $ for is $ \ i -> do
      writeDomain x $ Dom.singleton i
      dispatchPruning x Pruning.val
      return i

type ConditionalVars s = (HashSet (Var s), HashSet (Var s))

getConditionalTermVars :: Monad m => Term s -> FDT s m (ConditionalVars s)
getConditionalTermVars t = case t of
  Int _ ->
    return mempty
  t1 :+ t2 -> do
    (s1, g1) <- getConditionalTermVars t1
    (s2, g2) <- getConditionalTermVars t2
    return (s1 <> s2, g1 <> g2)
  t1 :- t2 -> do
    (s1, g1) <- getConditionalTermVars t1
    (s2, g2) <- getConditionalTermVars t2
    return (s1 <> g2, g1 <> s2)
  x :* t'
    | x >= 0 -> getConditionalTermVars t'
    | otherwise -> liftM swap $ getConditionalTermVars t'
  t' `Quot` x
    | x >= 0 -> getConditionalTermVars t'
    | otherwise -> liftM swap $ getConditionalTermVars t'
  t' `Div` x
    | x >= 0 -> getConditionalTermVars t'
    | otherwise -> liftM swap $ getConditionalTermVars t'
  Min x -> do
    determined <- isDetermined x
    return (if determined then mempty else HashSet.singleton x, mempty)
  Max x -> do
    determined <- isDetermined x
    return (mempty, if determined then mempty else HashSet.singleton x)

getConditionalRangeVars :: Monad m => Range s -> FDT s m (ConditionalVars s)
getConditionalRangeVars r = case r of
  t1 :.. t2 -> do
    (s1, g1) <- getConditionalTermVars t1
    (s2, g2) <- getConditionalTermVars t2
    return (g1 <> s2, s1 <> g2)
  Dom x -> do
    determined <- isDetermined x
    return (mempty, if determined then mempty else HashSet.singleton x)

isDetermined :: Monad m => Var s -> FDT s m Bool
isDetermined = liftM (Dom.sizeLE 1) . readDomain

termVars :: Term s -> HashMap (Var s) Pruning
termVars t = case t of
  Int _ -> HashMap.empty
  t1 :+ t2 -> (HashMap.unionWith Pruning.join `on` termVars) t1 t2
  t1 :- t2 -> (HashMap.unionWith Pruning.join `on` termVars) t1 t2
  _ :* t' -> termVars t'
  t' `Quot` _ -> termVars t'
  t' `Div` _ -> termVars t'
  Min x -> HashMap.singleton x Pruning.min
  Max x -> HashMap.singleton x Pruning.max

rangeVars :: Range s -> HashMap (Var s) Pruning
rangeVars r = case r of
  t1 :.. t2 -> (HashMap.unionWith Pruning.join `on` termVars) t1 t2
  Dom x -> HashMap.singleton x Pruning.dom

pruneDom :: Monad m => Range s -> Dom -> FDT s m (Maybe (Dom, Pruning))
pruneDom (t1 :.. t2) d = do
  i1 <- getVal t1
  i2 <- getVal t2
  return $ Dom.intersection d (Dom.fromBounds i1 i2)
pruneDom (Dom x) d =
  liftM (Dom.intersection d) $ readDomain x

dispatchPruning :: Monad m => Var s -> Pruning -> FDT s m ()
dispatchPruning x pruning = readListeners x >>= mapM_ ($ pruning) . toList

getVal :: Monad m => Term s -> FDT s m Int
getVal t = case t of
  Int i -> return i
  t1 :+ t2 -> liftM2 (+!) (getVal t1) (getVal t2)
  t1 :- t2 -> liftM2 (-!) (getVal t1) (getVal t2)
  x :* t' -> liftM (x *!) $ getVal t'
  _ `Quot` 0 -> mzero
  t' `Quot` x -> liftM (`quot` x) $ getVal t'
  _ `Div` 0 -> mzero
  t' `Div` x -> liftM (`div` x) $ getVal t'
  Min x -> liftM Dom.findMin $ readDomain x
  Max x -> liftM Dom.findMax $ readDomain x

data VarS s m =
  VarS { domain :: Dom
       , listeners :: DList (Listener s m)
       }

type Listener s m = Pruning -> FDT s m ()

initVarS :: VarS s m
initVarS = VarS { domain = Dom.full
                , listeners = mempty
                }

readVar :: Monad m => Var s -> FDT s m (VarS s m)
readVar x = liftM (!x) $ gets vars

readDomain :: Monad m => Var s -> FDT s m Dom
readDomain = liftM domain . readVar

modifyVar :: Monad m => Var s -> (VarS s m -> VarS s m) -> FDT s m ()
modifyVar x f = modify $ \ s@S {..} -> s { vars = HashMap.adjust f x vars }

writeDomain :: Monad m => Var s -> Dom -> FDT s m ()
writeDomain x d = modifyVar x $ \ s@VarS {..} -> s { domain = d }

readListeners :: Monad m => Var s -> FDT s m (DList (Listener s m))
readListeners = liftM listeners . readVar

addListener :: Monad m => Var s -> (Pruning -> FDT s m ()) -> FDT s m ()
addListener x listener = modifyVar x $ \ s@VarS {..} ->
  s { listeners = DList.snoc listeners listener }

newtype Propagator (s :: Region) =
  Propagator { unwrapPropagator :: Integer
             } deriving Eq

instance Hashable (Propagator s) where
  hash = hash . unwrapPropagator
  hashWithSalt salt = hashWithSalt salt . unwrapPropagator

data PropagatorS s =
  PropagatorS { monotoneVars :: MonotoneVars s
              , antimonotoneVars :: AntimonotoneVars s
              }

type MonotoneVars s = HashSet (Var s)
type AntimonotoneVars s = HashSet (Var s)

newPropagator :: Monad m =>
                 MonotoneVars s ->
                 AntimonotoneVars s ->
                 FDT s m (Propagator s)
newPropagator m a = do
  s@S {..} <- get
  let x = Propagator propagatorCount
  put s { propagatorCount = propagatorCount + 1
        , propagators = HashMap.insert x PropagatorS { monotoneVars = m
                                                     , antimonotoneVars = a
                                                     } propagators
        }
  return x

readPropagator :: Monad m => Propagator s -> FDT s m (PropagatorS s)
readPropagator x = liftM (!x) $ gets propagators

modifyMonotoneVars :: Monad m =>
                      Propagator s ->
                      (MonotoneVars s -> MonotoneVars s) ->
                      FDT s m ()
modifyMonotoneVars x f = modifyPropagator x $ \ s@PropagatorS {..} ->
   s { monotoneVars = f monotoneVars }

modifyAntimonotoneVars :: Monad m =>
                          Propagator s ->
                          (AntimonotoneVars s -> AntimonotoneVars s) ->
                          FDT s m ()
modifyAntimonotoneVars x f = modifyPropagator x $ \ s@PropagatorS {..} ->
  s { antimonotoneVars = f antimonotoneVars }

modifyPropagator :: Monad m =>
                    Propagator s ->
                    (PropagatorS s -> PropagatorS s) ->
                    FDT s m ()
modifyPropagator x f = modify $ \ s@S {..} ->
  s { propagators = HashMap.adjust f x propagators }

newtype Flag (s :: Region) = Flag { unwrapFlag :: Integer } deriving Eq

instance Hashable (Flag s) where
  hash = hash . unwrapFlag
  hashWithSalt salt = hashWithSalt salt . unwrapFlag

newFlag :: Monad m => FDT s m (Flag s)
newFlag = do
  s@S {..} <- get
  let flag = Flag flagCount
  put s { flagCount = flagCount + 1
        , unmarkedFlags = HashSet.insert flag unmarkedFlags
        }
  return flag

unlessMarked :: Monad m => Flag s -> FDT s m () -> FDT s m ()
unlessMarked flag m = do
  unmarked <- liftM (HashSet.member flag) (gets unmarkedFlags)
  when unmarked m

mark :: Monad m => Flag s -> FDT s m ()
mark flag = modify $ \ s@S {..} ->
  s { unmarkedFlags = HashSet.delete flag unmarkedFlags }

data Region

data S s m =
  S { varCount :: Integer
    , vars :: HashMap (Var s) (VarS s m)
    , propagatorCount :: Integer
    , propagators :: HashMap (Propagator s) (PropagatorS s)
    , flagCount :: Integer
    , unmarkedFlags :: HashSet (Flag s)
    }

initS :: Monad m => S s m
initS =
  S { varCount = toInteger (minBound :: Int)
    , vars = mempty
    , propagatorCount = toInteger (minBound :: Int)
    , propagators = mempty
    , flagCount = toInteger (minBound :: Int)
    , unmarkedFlags = mempty
    }

get :: Monad m => FDT s m (S s m)
get = FDT State.get

put :: Monad m => S s m -> FDT s m ()
put = FDT . State.put

modify :: Monad m => (S s m -> S s m) -> FDT s m ()
modify = FDT . State.modify

gets :: Monad m => (S s m -> a) -> FDT s m a
gets = FDT . State.gets

whenNothing :: Monad m => Maybe a -> m () -> m ()
whenNothing p m = maybe m (const $ return ()) p

for :: [a] -> (a -> b) -> [b]
for = flip map