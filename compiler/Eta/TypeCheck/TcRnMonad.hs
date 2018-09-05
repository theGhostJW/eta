{-
(c) The University of Glasgow 2006


Functions for working with the typechecker environment (setters, getters...).
-}

{-# LANGUAGE CPP, ExplicitForAll, FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Eta.TypeCheck.TcRnMonad(
        module Eta.TypeCheck.TcRnMonad,
        module Eta.TypeCheck.TcRnTypes,
        module Eta.Utils.IOEnv
  ) where

import Eta.TypeCheck.TcRnTypes        -- Re-export all
import Eta.Utils.IOEnv            -- Re-export all
import Eta.TypeCheck.TcEvidence
import {-# SOURCE #-} Eta.TypeCheck.TcSplice (runRemoteModFinalizers)
import Eta.HsSyn.HsSyn hiding (LIE)
import Eta.Main.HscTypes
import Eta.BasicTypes.Module
import Eta.BasicTypes.RdrName
import Eta.BasicTypes.Name
import Eta.Types.Type
import Eta.Main.Error
import Eta.Main.ErrorReporting
import Eta.TypeCheck.TcType
import Eta.Types.InstEnv
import Eta.Types.FamInstEnv
import Eta.Prelude.PrelNames
import Eta.Utils.Maybes
import Eta.BasicTypes.Var
import Eta.BasicTypes.Id
import Eta.BasicTypes.VarSet
import Eta.BasicTypes.VarEnv
import Eta.Main.ErrUtils
import Eta.BasicTypes.SrcLoc
import Eta.BasicTypes.NameEnv
import Eta.BasicTypes.NameSet
import Eta.Utils.Bag
import Eta.Utils.Outputable
import Eta.BasicTypes.UniqSupply
import Eta.Utils.UniqFM
import Eta.Main.DynFlags
import Eta.Main.StaticFlags
import Eta.Utils.FastString
import Eta.Utils.Panic
import Eta.Utils.Util
import Eta.Main.Annotations
import Eta.BasicTypes.BasicTypes( TopLevelFlag )

import Control.Exception
import Data.IORef
import qualified Data.Set as Set
import Control.Monad
import qualified Eta.LanguageExtensions as LangExt
#ifdef ETA_REPL
import qualified Data.Map as Map
#endif

{-
************************************************************************
*                                                                      *
                        initTc
*                                                                      *
************************************************************************
-}

-- | Setup the initial typechecking environment
initTc :: HscEnv
       -> HscSource
       -> Bool          -- True <=> retain renamed syntax trees
       -> Module
       -> RealSrcSpan
       -> TcM r
       -> IO (Messages, Maybe r)
                -- Nothing => error thrown by the thing inside
                -- (error messages should have been printed already)

initTc hsc_env hsc_src keep_rn_syntax mod loc do_this
 = do { errs_var     <- newIORef (emptyBag, emptyBag) ;
        tvs_var      <- newIORef emptyVarSet ;
        keep_var     <- newIORef emptyNameSet ;
        used_rdr_var <- newIORef Set.empty ;
        th_var       <- newIORef False ;
        th_splice_var<- newIORef False ;
        infer_var    <- newIORef True ;
        lie_var      <- newIORef emptyWC ;
        dfun_n_var   <- newIORef emptyOccSet ;
        type_env_var <- case hsc_type_env_var hsc_env of {
                           Just (_mod, te_var) -> return te_var ;
                           Nothing             -> newIORef emptyNameEnv } ;

        dependent_files_var <- newIORef [] ;
        static_wc_var       <- newIORef emptyWC ;
#ifdef ETA_REPL
        th_topdecls_var      <- newIORef [] ;
        th_topnames_var      <- newIORef emptyNameSet ;
        th_modfinalizers_var <- newIORef [] ;
        th_state_var         <- newIORef Map.empty ;
        th_remote_state_var  <- newIORef Nothing ;
#endif /* ETA_REPL */
        let {
             dflags = hsc_dflags hsc_env ;

             maybe_rn_syntax :: forall a. a -> Maybe a ;
             maybe_rn_syntax empty_val
                | keep_rn_syntax = Just empty_val
                | otherwise      = Nothing ;

             gbl_env = TcGblEnv {
#ifdef ETA_REPL
                tcg_th_topdecls      = th_topdecls_var,
                tcg_th_topnames      = th_topnames_var,
                tcg_th_modfinalizers = th_modfinalizers_var,
                tcg_th_state         = th_state_var,
                tcg_th_remote_state  = th_remote_state_var,
#endif /* ETA_REPL */

                tcg_mod             = mod,
                tcg_semantic_mod    =
                    if thisPackage dflags == moduleUnitId mod
                        then canonicalizeHomeModule dflags (moduleName mod)
                        else mod,
                tcg_src             = hsc_src,
                tcg_rdr_env         = emptyGlobalRdrEnv,
                tcg_fix_env         = emptyNameEnv,
                tcg_field_env       = RecFields emptyNameEnv emptyNameSet,
                tcg_default         = Nothing,
                tcg_type_env        = emptyNameEnv,
                tcg_type_env_var    = type_env_var,
                tcg_inst_env        = emptyInstEnv,
                tcg_fam_inst_env    = emptyFamInstEnv,
                tcg_ann_env         = emptyAnnEnv,
                tcg_visible_orphan_mods = mkModuleSet [mod],
                tcg_th_used         = th_var,
                tcg_th_splice_used  = th_splice_var,
                tcg_exports         = [],
                tcg_imports         = emptyImportAvails,
                tcg_used_rdrnames   = used_rdr_var,
                tcg_dus             = emptyDUs,

                tcg_rn_imports      = [],
                tcg_rn_exports      =
                    if hsc_src == HsigFile
                        -- Always retain renamed syntax, so that we can give
                        -- better errors.  (TODO: how?)
                        then Just []
                        else maybe_rn_syntax [],
                tcg_rn_decls        = maybe_rn_syntax emptyRnGroup,

                tcg_binds           = emptyLHsBinds,
                tcg_imp_specs       = [],
                tcg_sigs            = emptyNameSet,
                tcg_ev_binds        = emptyBag,
                tcg_warns           = NoWarnings,
                tcg_anns            = [],
                tcg_tcs             = [],
                tcg_insts           = [],
                tcg_fam_insts       = [],
                tcg_rules           = [],
                tcg_fords           = [],
                tcg_vects           = [],
                tcg_patsyns         = [],
                tcg_merged          = [],
                tcg_dfun_n          = dfun_n_var,
                tcg_keep            = keep_var,
                tcg_doc_hdr         = Nothing,
                tcg_hpc             = False,
                tcg_main            = Nothing,
                tcg_self_boot       = NoSelfBoot,
                tcg_safeInfer       = infer_var,
                tcg_dependent_files = dependent_files_var,
                tcg_tc_plugins      = [],
                tcg_top_loc         = loc,
                tcg_static_wc       = static_wc_var
             } ;
             lcl_env = TcLclEnv {
                tcl_errs       = errs_var,
                tcl_loc        = loc,     -- Should be over-ridden very soon!
                tcl_ctxt       = [],
                tcl_rdr        = emptyLocalRdrEnv,
                tcl_th_ctxt    = topStage,
                tcl_th_bndrs   = emptyNameEnv,
                tcl_arrow_ctxt = NoArrowCtxt,
                tcl_env        = emptyNameEnv,
                tcl_bndrs      = [],
                tcl_tidy       = emptyTidyEnv,
                tcl_tyvars     = tvs_var,
                tcl_lie        = lie_var,
                tcl_tclvl      = topTcLevel
             } ;
        } ;

        -- OK, here's the business end!
        maybe_res <- initTcRnIf 'a' hsc_env gbl_env lcl_env $
                     do { r <- tryM do_this
                        ; case r of
                          Right res -> return (Just res)
                          Left _    -> return Nothing } ;

        -- Check for unsolved constraints
        lie <- readIORef lie_var ;
        if isEmptyWC lie
           then return ()
           else pprPanic "initTc: unsolved constraints" (ppr lie) ;

        -- Collect any error messages
        msgs <- readIORef errs_var ;

        let { final_res | errorsFound dflags msgs = Nothing
                        | otherwise               = maybe_res } ;

        return (msgs, final_res)
    }


initTcInteractive :: HscEnv -> TcM a -> IO (Messages, Maybe a)
-- Initialise the type checker monad for use in GHCi
initTcInteractive hsc_env thing_inside
  = initTc hsc_env HsSrcFile False
           (icInteractiveModule (hsc_IC hsc_env))
           (realSrcLocSpan interactive_src_loc)
           thing_inside
  where
    interactive_src_loc = mkRealSrcLoc (fsLit "<interactive>") 1 1

initTcForLookup :: HscEnv -> TcM a -> IO a
-- The thing_inside is just going to look up something
-- in the environment, so we don't need much setup
initTcForLookup hsc_env thing_inside
  = do { (msgs, m) <- initTcInteractive hsc_env thing_inside
       ; case m of
             Nothing -> throwIO $ mkSrcErr $ renderErrors $ snd msgs
             Just x -> return x }

{-
************************************************************************
*                                                                      *
                Initialisation
*                                                                      *
************************************************************************
-}

initTcRnIf :: Char              -- Tag for unique supply
           -> HscEnv
           -> gbl -> lcl
           -> TcRnIf gbl lcl a
           -> IO a
initTcRnIf uniq_tag hsc_env gbl_env lcl_env thing_inside
   = do { us     <- mkSplitUniqSupply uniq_tag ;
        ; us_var <- newIORef us ;

        ; let { env = Env { env_top = hsc_env,
                            env_us  = us_var,
                            env_gbl = gbl_env,
                            env_lcl = lcl_env} }

        ; runIOEnv env thing_inside
        }

{-
************************************************************************
*                                                                      *
                Simple accessors
*                                                                      *
************************************************************************
-}

discardResult :: TcM a -> TcM ()
discardResult a = a >> return ()

getTopEnv :: TcRnIf gbl lcl HscEnv
getTopEnv = do { env <- getEnv; return (env_top env) }

updTopEnv :: (HscEnv -> HscEnv) -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
updTopEnv upd = updEnv (\ env@(Env { env_top = top }) ->
                          env { env_top = upd top })

getGblEnv :: TcRnIf gbl lcl gbl
getGblEnv = do { env <- getEnv; return (env_gbl env) }

updGblEnv :: (gbl -> gbl) -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
updGblEnv upd = updEnv (\ env@(Env { env_gbl = gbl }) ->
                          env { env_gbl = upd gbl })

setGblEnv :: gbl -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
setGblEnv gbl_env = updEnv (\ env -> env { env_gbl = gbl_env })

getLclEnv :: TcRnIf gbl lcl lcl
getLclEnv = do { env <- getEnv; return (env_lcl env) }

updLclEnv :: (lcl -> lcl) -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
updLclEnv upd = updEnv (\ env@(Env { env_lcl = lcl }) ->
                          env { env_lcl = upd lcl })

setLclEnv :: lcl' -> TcRnIf gbl lcl' a -> TcRnIf gbl lcl a
setLclEnv lcl_env = updEnv (\ env -> env { env_lcl = lcl_env })

getEnvs :: TcRnIf gbl lcl (gbl, lcl)
getEnvs = do { env <- getEnv; return (env_gbl env, env_lcl env) }

setEnvs :: (gbl', lcl') -> TcRnIf gbl' lcl' a -> TcRnIf gbl lcl a
setEnvs (gbl_env, lcl_env) = updEnv (\ env -> env { env_gbl = gbl_env, env_lcl = lcl_env })

-- Command-line flags

xoptM :: LangExt.Extension -> TcRnIf gbl lcl Bool
xoptM flag = do { dflags <- getDynFlags; return (xopt flag dflags) }

doptM :: DumpFlag -> TcRnIf gbl lcl Bool
doptM flag = do { dflags <- getDynFlags; return (dopt flag dflags) }

goptM :: GeneralFlag -> TcRnIf gbl lcl Bool
goptM flag = do { dflags <- getDynFlags; return (gopt flag dflags) }

woptM :: WarningFlag -> TcRnIf gbl lcl Bool
woptM flag = do { dflags <- getDynFlags; return (wopt flag dflags) }

setXOptM :: LangExt.Extension -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
setXOptM flag = updEnv (\ env@(Env { env_top = top }) ->
                          env { env_top = top { hsc_dflags = xopt_set (hsc_dflags top) flag}} )

unsetGOptM :: GeneralFlag -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
unsetGOptM flag = updEnv (\ env@(Env { env_top = top }) ->
                            env { env_top = top { hsc_dflags = gopt_unset (hsc_dflags top) flag}} )

unsetWOptM :: WarningFlag -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
unsetWOptM flag = updEnv (\ env@(Env { env_top = top }) ->
                            env { env_top = top { hsc_dflags = wopt_unset (hsc_dflags top) flag}} )

-- | Do it flag is true
whenDOptM :: DumpFlag -> TcRnIf gbl lcl () -> TcRnIf gbl lcl ()
whenDOptM flag thing_inside = do b <- doptM flag
                                 when b thing_inside

whenGOptM :: GeneralFlag -> TcRnIf gbl lcl () -> TcRnIf gbl lcl ()
whenGOptM flag thing_inside = do b <- goptM flag
                                 when b thing_inside

whenWOptM :: WarningFlag -> TcRnIf gbl lcl () -> TcRnIf gbl lcl ()
whenWOptM flag thing_inside = do b <- woptM flag
                                 when b thing_inside

whenXOptM :: LangExt.Extension -> TcRnIf gbl lcl () -> TcRnIf gbl lcl ()
whenXOptM flag thing_inside = do b <- xoptM flag
                                 when b thing_inside

getGhcMode :: TcRnIf gbl lcl GhcMode
getGhcMode = do { env <- getTopEnv; return (ghcMode (hsc_dflags env)) }

withDoDynamicToo :: TcRnIf gbl lcl a -> TcRnIf gbl lcl a
withDoDynamicToo m = do env <- getEnv
                        let dflags = extractDynFlags env
                            dflags' = dynamicTooMkDynamicDynFlags dflags
                            env' = replaceDynFlags env dflags'
                        setEnv env' m

getEpsVar :: TcRnIf gbl lcl (TcRef ExternalPackageState)
getEpsVar = do { env <- getTopEnv; return (hsc_EPS env) }

getEps :: TcRnIf gbl lcl ExternalPackageState
getEps = do { env <- getTopEnv; readMutVar (hsc_EPS env) }

-- | Update the external package state.  Returns the second result of the
-- modifier function.
--
-- This is an atomic operation and forces evaluation of the modified EPS in
-- order to avoid space leaks.
updateEps :: (ExternalPackageState -> (ExternalPackageState, a))
          -> TcRnIf gbl lcl a
updateEps upd_fn = do
  traceIf (text "updating EPS")
  eps_var <- getEpsVar
  atomicUpdMutVar' eps_var upd_fn

-- | Update the external package state.
--
-- This is an atomic operation and forces evaluation of the modified EPS in
-- order to avoid space leaks.
updateEps_ :: (ExternalPackageState -> ExternalPackageState)
           -> TcRnIf gbl lcl ()
updateEps_ upd_fn = do
  traceIf (text "updating EPS_")
  eps_var <- getEpsVar
  atomicUpdMutVar' eps_var (\eps -> (upd_fn eps, ()))

getHpt :: TcRnIf gbl lcl HomePackageTable
getHpt = do { env <- getTopEnv; return (hsc_HPT env) }

getEpsAndHpt :: TcRnIf gbl lcl (ExternalPackageState, HomePackageTable)
getEpsAndHpt = do { env <- getTopEnv; eps <- readMutVar (hsc_EPS env)
                  ; return (eps, hsc_HPT env) }

-- | A convenient wrapper for taking a @MaybeErr MsgDoc a@ and throwing
-- an exception if it is an error.
withException :: TcRnIf gbl lcl (MaybeErr TypeError a) -> TcRnIf gbl lcl a
withException do_this = do
    r <- do_this
    dflags <- getDynFlags
    case r of
        Failed err -> liftIO $ throwGhcExceptionIO (ProgramError (showSDoc dflags (ppr err)))
        Succeeded result -> return result

{-
************************************************************************
*                                                                      *
                Arrow scopes
*                                                                      *
************************************************************************
-}

newArrowScope :: TcM a -> TcM a
newArrowScope
  = updLclEnv $ \env -> env { tcl_arrow_ctxt = ArrowCtxt (tcl_rdr env) (tcl_lie env) }

-- Return to the stored environment (from the enclosing proc)
escapeArrowScope :: TcM a -> TcM a
escapeArrowScope
  = updLclEnv $ \ env ->
    case tcl_arrow_ctxt env of
      NoArrowCtxt       -> env
      ArrowCtxt rdr_env lie -> env { tcl_arrow_ctxt = NoArrowCtxt
                                   , tcl_lie = lie
                                   , tcl_rdr = rdr_env }

{-
************************************************************************
*                                                                      *
                Unique supply
*                                                                      *
************************************************************************
-}

newUnique :: TcRnIf gbl lcl Unique
newUnique
 = do { env <- getEnv ;
        let { u_var = env_us env } ;
        us <- readMutVar u_var ;
        case takeUniqFromSupply us of { (uniq, us') -> do {
        writeMutVar u_var us' ;
        return $! uniq }}}
   -- NOTE 1: we strictly split the supply, to avoid the possibility of leaving
   -- a chain of unevaluated supplies behind.
   -- NOTE 2: we use the uniq in the supply from the MutVar directly, and
   -- throw away one half of the new split supply.  This is safe because this
   -- is the only place we use that unique.  Using the other half of the split
   -- supply is safer, but slower.

newUniqueSupply :: TcRnIf gbl lcl UniqSupply
newUniqueSupply
 = do { env <- getEnv ;
        let { u_var = env_us env } ;
        us <- readMutVar u_var ;
        case splitUniqSupply us of { (us1,us2) -> do {
        writeMutVar u_var us1 ;
        return us2 }}}

newLocalName :: Name -> TcM Name
newLocalName name = newName (nameOccName name)

newName :: OccName -> TcM Name
newName occ
  = do { uniq <- newUnique
       ; loc  <- getSrcSpanM
       ; return (mkInternalName uniq occ loc) }

newSysName :: OccName -> TcM Name
newSysName occ
  = do { uniq <- newUnique
       ; return (mkSystemName uniq occ) }

newSysLocalId :: FastString -> TcType -> TcRnIf gbl lcl TcId
newSysLocalId fs ty
  = do  { u <- newUnique
        ; return (mkSysLocal fs u ty) }

newSysLocalIds :: FastString -> [TcType] -> TcRnIf gbl lcl [TcId]
newSysLocalIds fs tys
  = do  { us <- newUniqueSupply
        ; return (zipWith (mkSysLocal fs) (uniqsFromSupply us) tys) }

instance MonadUnique (IOEnv (Env gbl lcl)) where
        getUniqueM = newUnique
        getUniqueSupplyM = newUniqueSupply

{-
************************************************************************
*                                                                      *
                Debugging
*                                                                      *
************************************************************************
-}

newTcRef :: a -> TcRnIf gbl lcl (TcRef a)
newTcRef = newMutVar

readTcRef :: TcRef a -> TcRnIf gbl lcl a
readTcRef = readMutVar

writeTcRef :: TcRef a -> a -> TcRnIf gbl lcl ()
writeTcRef = writeMutVar

updTcRef :: TcRef a -> (a -> a) -> TcRnIf gbl lcl ()
-- Returns ()
updTcRef ref fn = liftIO $ do { old <- readIORef ref
                              ; writeIORef ref (fn old) }

updTcRefX :: TcRef a -> (a -> a) -> TcRnIf gbl lcl a
-- Returns previous value
updTcRefX ref fn = liftIO $ do { old <- readIORef ref
                              ; writeIORef ref (fn old)
                              ; return old }

{-
************************************************************************
*                                                                      *
                Debugging
*                                                                      *
************************************************************************
-}

traceTc :: String -> SDoc -> TcRn ()
traceTc herald doc = traceTcN 1 (hang (text herald) 2 doc)

-- | Typechecker trace
traceTcN :: Int -> SDoc -> TcRn ()
traceTcN level doc
    = do dflags <- getDynFlags
         when (level <= traceLevel dflags && not opt_NoDebugOutput) $
             traceOptTcRn Opt_D_dump_tc_trace doc

-- Renamer Trace
traceRn :: String -> SDoc -> TcRn ()
traceRn =
 labelledTraceOptTcRn Opt_D_dump_rn_trace

-- | Trace when a certain flag is enabled. This is like `traceOptTcRn`
-- but accepts a string as a label and formats the trace message uniformly.
labelledTraceOptTcRn :: DumpFlag -> String -> SDoc -> TcRn ()
labelledTraceOptTcRn flag herald doc = do
  traceOptTcRn flag (formatTraceMsg herald doc)

formatTraceMsg :: String -> SDoc -> SDoc
formatTraceMsg herald doc = hang (text herald) 2 doc

-- | Output a doc if the given 'DumpFlag' is set.
--
-- By default this logs to stdout
-- However, if the `-ddump-to-file` flag is set,
-- then this will dump output to a file
--
-- Just a wrapper for 'dumpSDoc'
traceOptTcRn :: DumpFlag -> SDoc -> TcRn ()
traceOptTcRn flag doc
  = do { dflags <- getDynFlags
       ; when (dopt flag dflags) (traceTcRn flag doc)
    }

traceTcRn :: DumpFlag -> SDoc -> TcRn ()
-- ^ Unconditionally dump some trace output
--
-- The DumpFlag is used only to set the output filename
-- for --dump-to-file, not to decide whether or not to output
-- That part is done by the caller
traceTcRn flag doc
  = do { real_doc <- prettyDoc doc
       ; dflags   <- getDynFlags
       ; printer  <- getPrintUnqualified dflags
       ; liftIO $ dumpSDoc dflags printer flag "" real_doc  }
  where
    -- Add current location if opt_PprStyle_Debug
    prettyDoc :: SDoc -> TcRn SDoc
    prettyDoc doc = if opt_PprStyle_Debug
       then do { loc  <- getSrcSpanM; return $ mkLocMessage SevOutput loc doc }
       else return doc -- The full location is usually way too much


getPrintUnqualified :: DynFlags -> TcRn PrintUnqualified
getPrintUnqualified dflags
  = do { rdr_env <- getGlobalRdrEnv
       ; return $ mkPrintUnqualified dflags rdr_env }

-- | Like logInfoTcRn, but for user consumption
printForUserTcRn :: SDoc -> TcRn ()
printForUserTcRn doc
  = do { dflags <- getDynFlags
       ; printer <- getPrintUnqualified dflags
       ; liftIO (printInfoForUser dflags printer doc) }

-- | Typechecker debug
debugDumpTcRn :: SDoc -> TcRn ()
debugDumpTcRn doc = unless opt_NoDebugOutput $
                    traceOptTcRn Opt_D_dump_tc doc

{-
traceIf and traceHiDiffs work in the TcRnIf monad, where no RdrEnv is
available.  Alas, they behave inconsistently with the other stuff;
e.g. are unaffected by -dump-to-file.
-}

traceIf, traceHiDiffs :: SDoc -> TcRnIf m n ()
traceIf      = traceOptIf Opt_D_dump_if_trace
traceHiDiffs = traceOptIf Opt_D_dump_hi_diffs


traceOptIf :: DumpFlag -> SDoc -> TcRnIf m n ()
traceOptIf flag doc
  = whenDOptM flag $    -- No RdrEnv available, so qualify everything
    do { dflags <- getDynFlags
       ; liftIO (putMsg dflags doc) }

{-
************************************************************************
*                                                                      *
                Typechecker global environment
*                                                                      *
************************************************************************
-}
--
-- setModule :: Module -> TcRn a -> TcRn a
-- setModule mod thing_inside = updGblEnv (\env -> env { tcg_mod = mod }) thing_inside

getIsGHCi :: TcRn Bool
getIsGHCi = do { mod <- getModule
               ; return (isInteractiveModule mod) }

getGHCiMonad :: TcRn Name
getGHCiMonad = do { hsc <- getTopEnv; return (ic_monad $ hsc_IC hsc) }

getInteractivePrintName :: TcRn Name
getInteractivePrintName = do { hsc <- getTopEnv; return (ic_int_print $ hsc_IC hsc) }

getItName :: SrcSpan -> TcRn Name
getItName loc = do
  hsc  <- getTopEnv
  itNo <- icItCounterInc (hsc_IC hsc)
  uniq <- newUnique
  return $ itName (fromIntegral itNo) uniq loc

tcIsHsBootOrSig :: TcRn Bool
tcIsHsBootOrSig = do { env <- getGblEnv; return (isHsBootOrSig (tcg_src env)) }

tcSelfBootInfo :: TcRn SelfBootInfo
tcSelfBootInfo = do { env <- getGblEnv; return (tcg_self_boot env) }

getGlobalRdrEnv :: TcRn GlobalRdrEnv
getGlobalRdrEnv = do { env <- getGblEnv; return (tcg_rdr_env env) }

getRdrEnvs :: TcRn (GlobalRdrEnv, LocalRdrEnv)
getRdrEnvs = do { (gbl,lcl) <- getEnvs; return (tcg_rdr_env gbl, tcl_rdr lcl) }

getImports :: TcRn ImportAvails
getImports = do { env <- getGblEnv; return (tcg_imports env) }

getFixityEnv :: TcRn FixityEnv
getFixityEnv = do { env <- getGblEnv; return (tcg_fix_env env) }

extendFixityEnv :: [(Name,FixItem)] -> RnM a -> RnM a
extendFixityEnv new_bit
  = updGblEnv (\env@(TcGblEnv { tcg_fix_env = old_fix_env }) ->
                env {tcg_fix_env = extendNameEnvList old_fix_env new_bit})

getRecFieldEnv :: TcRn RecFieldEnv
getRecFieldEnv = do { env <- getGblEnv; return (tcg_field_env env) }

getDeclaredDefaultTys :: TcRn (Maybe [Type])
getDeclaredDefaultTys = do { env <- getGblEnv; return (tcg_default env) }

addDependentFiles :: [FilePath] -> TcRn ()
addDependentFiles fs = do
  ref <- fmap tcg_dependent_files getGblEnv
  dep_files <- readTcRef ref
  writeTcRef ref (fs ++ dep_files)

{-
************************************************************************
*                                                                      *
                Error management
*                                                                      *
************************************************************************
-}

getSrcSpanM :: TcRn SrcSpan
        -- Avoid clash with Name.getSrcLoc
getSrcSpanM = do { env <- getLclEnv; return (RealSrcSpan (tcl_loc env)) }

setSrcSpan :: SrcSpan -> TcRn a -> TcRn a
setSrcSpan (RealSrcSpan real_loc) thing_inside
    = updLclEnv (\env -> env { tcl_loc = real_loc }) thing_inside
-- Don't overwrite useful info with useless:
setSrcSpan (UnhelpfulSpan _) thing_inside = thing_inside

addLocM :: (a -> TcM b) -> Located a -> TcM b
addLocM fn (L loc a) = setSrcSpan loc $ fn a

wrapLocM :: (a -> TcM b) -> Located a -> TcM (Located b)
wrapLocM fn (L loc a) = setSrcSpan loc $ do b <- fn a; return (L loc b)

wrapLocFstM :: (a -> TcM (b,c)) -> Located a -> TcM (Located b, c)
wrapLocFstM fn (L loc a) =
  setSrcSpan loc $ do
    (b,c) <- fn a
    return (L loc b, c)

wrapLocSndM :: (a -> TcM (b,c)) -> Located a -> TcM (b, Located c)
wrapLocSndM fn (L loc a) =
  setSrcSpan loc $ do
    (b,c) <- fn a
    return (b, L loc c)

-- Reporting errors

getErrsVar :: TcRn (TcRef Messages)
getErrsVar = do { env <- getLclEnv; return (tcl_errs env) }

setErrsVar :: TcRef Messages -> TcRn a -> TcRn a
setErrsVar v = updLclEnv (\ env -> env { tcl_errs =  v })

addErr :: TypeError -> TcRn ()    -- Ignores the context stack
addErr msg = do { loc <- getSrcSpanM; addErrAt loc msg }

failWith :: TypeError -> TcRn a
failWith msg = addErr msg >> failM

addErrAt :: SrcSpan -> TypeError -> TcRn ()
-- addErrAt is mainly (exclusively?) used by the renamer, where
-- tidying is not an issue, but it's all lazy so the extra
-- work doesn't matter
addErrAt loc msg = do { ctxt <- getErrCtxt
                      ; tidy_env <- tcInitTidyEnv
                      ; err_info <- mkErrInfo tidy_env ctxt
                      ; addLongErrAt loc msg err_info }

addErrs :: [(SrcSpan,TypeError)] -> TcRn ()
addErrs msgs = mapM_ add msgs
             where
               add (loc,msg) = addErrAt loc msg

checkErr :: Bool -> TypeError -> TcRn ()
-- Add the error if the bool is False
checkErr ok msg = unless ok (addErr msg)

-- | Display a warning if a condition is met,
--   and the warning is enabled
warnIfFlag :: WarningFlag -> Bool -> MsgDoc -> TcRn ()
warnIfFlag warn_flag is_bad msg
  = do { warn_on <- woptM warn_flag


       ; when (warn_on && is_bad) $
         addWarn (Reason warn_flag) msg }

-- | Display a warning if a condition is met.
warnIf :: Bool -> MsgDoc -> TcRn ()
warnIf is_bad msg
  = when is_bad (addWarn NoReason msg)

addMessages :: Messages -> TcRn ()
addMessages (m_warns, m_errs)
  = do { errs_var <- getErrsVar ;
         (warns, errs) <- readTcRef errs_var ;
         writeTcRef errs_var (warns `unionBags` m_warns,
                               errs  `unionBags` m_errs) }

discardWarnings :: TcRn a -> TcRn a
-- Ignore warnings inside the thing inside;
-- used to ignore-unused-variable warnings inside derived code
discardWarnings thing_inside
  = do  { errs_var <- getErrsVar
        ; (old_warns, _) <- readTcRef errs_var ;

        ; result <- thing_inside

        -- Revert warnings to old_warns
        ; (_new_warns, new_errs) <- readTcRef errs_var
        ; writeTcRef errs_var (old_warns, new_errs)

        ; return result }

{-
************************************************************************
*                                                                      *
        Shared error message stuff: renamer and typechecker
*                                                                      *
************************************************************************
-}

mkLongErrAt :: SrcSpan -> TypeError -> [ContextElement] -> TcRn ErrMsg
mkLongErrAt loc msg extra
  = do { dflags <- getDynFlags ;
         printer <- getPrintUnqualified dflags ;
         return $ mkLongErrMsg dflags loc printer msg extra }

addLongErrAt :: SrcSpan -> TypeError -> [ContextElement] -> TcRn ()
addLongErrAt loc msg extra = mkLongErrAt loc msg extra >>= reportError

reportErrors :: [ErrMsg] -> TcM ()
reportErrors = mapM_ reportError

reportError :: ErrMsg -> TcRn ()
reportError err
  = do { traceTc "Adding error:" (pprLocErrMsg err) ;
         errs_var <- getErrsVar ;
         (warns, errs) <- readTcRef errs_var ;
         writeTcRef errs_var (warns, errs `snocBag` err) }

reportWarning :: ErrMsg -> TcRn ()
reportWarning warn
  = do { traceTc "Adding warning:" (pprLocErrMsg warn) ;
         errs_var <- getErrsVar ;
         (warns, errs) <- readTcRef errs_var ;
         writeTcRef errs_var (warns `snocBag` warn, errs) }

try_m :: TcRn r -> TcRn (Either IOEnvFailure r)
-- Does tryM, with a debug-trace on failure
try_m thing
  = do { (mb_r, lie) <- tryCaptureConstraints thing
       ; emitConstraints lie

       -- Debug trace
       ; case mb_r of
            Left exn -> traceTc "tryTc/recoverM recovering from" $
                        text (showException exn)
            Right {} -> return ()

       ; return mb_r }

-----------------------
recoverM :: TcRn r      -- Recovery action; do this if the main one fails
         -> TcRn r      -- Main action: do this first
         -> TcRn r
-- Errors in 'thing' are retained
recoverM recover thing
  = do { mb_res <- try_m thing ;
         case mb_res of
           Left _    -> recover
           Right res -> return res }


-----------------------
mapAndRecoverM :: (a -> TcRn b) -> [a] -> TcRn [b]
-- Drop elements of the input that fail, so the result
-- list can be shorter than the argument list
mapAndRecoverM _ []     = return []
mapAndRecoverM f (x:xs) = do { mb_r <- try_m (f x)
                             ; rs <- mapAndRecoverM f xs
                             ; return (case mb_r of
                                          Left _  -> rs
                                          Right r -> r:rs) }

-- | Succeeds if applying the argument to all members of the lists succeeds,
--   but nevertheless runs it on all arguments, to collect all errors.
mapAndReportM :: (a -> TcRn b) -> [a] -> TcRn [b]
mapAndReportM f xs = checkNoErrs (mapAndRecoverM f xs)

-----------------------
tryTc :: TcRn a -> TcRn (Messages, Maybe a)
-- (tryTc m) executes m, and returns
--      Just r,  if m succeeds (returning r)
--      Nothing, if m fails
-- It also returns all the errors and warnings accumulated by m
-- It always succeeds (never raises an exception)
tryTc m
 = do { errs_var <- newTcRef emptyMessages ;
        res  <- try_m (setErrsVar errs_var m) ;
        msgs <- readTcRef errs_var ;
        return (msgs, case res of
                            Left _  -> Nothing
                            Right val -> Just val)
        -- The exception is always the IOEnv built-in
        -- in exception; see IOEnv.failM
   }

-----------------------
tryTcErrs :: TcRn a -> TcRn (Messages, Maybe a)
-- Run the thing, returning
--      Just r,  if m succceeds with no error messages
--      Nothing, if m fails, or if it succeeds but has error messages
-- Either way, the messages are returned; even in the Just case
-- there might be warnings
tryTcErrs thing
  = do  { (msgs, res) <- tryTc thing
        ; dflags <- getDynFlags
        ; let errs_found = errorsFound dflags msgs
        ; return (msgs, case res of
                          Nothing -> Nothing
                          Just val | errs_found -> Nothing
                                   | otherwise  -> Just val)
        }

-----------------------
tryTcLIE :: TcM a -> TcM (Messages, Maybe a)
-- Just like tryTcErrs, except that it ensures that the LIE
-- for the thing is propagated only if there are no errors
-- Hence it's restricted to the type-check monad
tryTcLIE thing_inside
  = do  { ((msgs, mb_res), lie) <- captureConstraints (tryTcErrs thing_inside) ;
        ; case mb_res of
            Nothing  -> return (msgs, Nothing)
            Just val -> do { emitConstraints lie; return (msgs, Just val) }
        }

-----------------------
tryTcLIE_ :: TcM r -> TcM r -> TcM r
-- (tryTcLIE_ r m) tries m;
--      if m succeeds with no error messages, it's the answer
--      otherwise tryTcLIE_ drops everything from m and tries r instead.
tryTcLIE_ recover main
  = do  { (msgs, mb_res) <- tryTcLIE main
        ; case mb_res of
             Just val -> do { addMessages msgs  -- There might be warnings
                             ; return val }
             Nothing  -> recover                -- Discard all msgs
        }

-----------------------
checkNoErrs :: TcM r -> TcM r
-- (checkNoErrs m) succeeds iff m succeeds and generates no errors
-- If m fails then (checkNoErrsTc m) fails.
-- If m succeeds, it checks whether m generated any errors messages
--      (it might have recovered internally)
--      If so, it fails too.
-- Regardless, any errors generated by m are propagated to the enclosing context.
checkNoErrs main
  = do  { (msgs, mb_res) <- tryTcLIE main
        ; addMessages msgs
        ; case mb_res of
            Nothing  -> failM
            Just val -> return val
        }

whenNoErrs :: TcM () -> TcM ()
whenNoErrs thing = ifErrsM (return ()) thing

ifErrsM :: TcRn r -> TcRn r -> TcRn r
--      ifErrsM bale_out normal
-- does 'bale_out' if there are errors in errors collection
-- otherwise does 'normal'
ifErrsM bale_out normal
 = do { errs_var <- getErrsVar ;
        msgs <- readTcRef errs_var ;
        dflags <- getDynFlags ;
        if errorsFound dflags msgs then
           bale_out
        else
           normal }

failIfErrsM :: TcRn ()
-- Useful to avoid error cascades
failIfErrsM = ifErrsM failM (return ())

checkTH :: Outputable a => a -> String -> TcRn ()
#ifdef ETA_REPL
checkTH _ _ = return () -- OK
#else
checkTH e what = failTH e what  -- Raise an error in a stage-1 compiler
#endif

failTH :: Outputable a => a -> String -> TcRn x
failTH e what  -- Raise an error in a stage-1 compiler
  = failWithTc (FailTHError what (ppr e))

{-
************************************************************************
*                                                                      *
        Context management for the type checker
*                                                                      *
************************************************************************
-}

getErrCtxt :: TcM [ErrCtxt]
getErrCtxt = do { env <- getLclEnv; return (tcl_ctxt env) }

setErrCtxt :: [ErrCtxt] -> TcM a -> TcM a
setErrCtxt ctxt = updLclEnv (\ env -> env { tcl_ctxt = ctxt })

addErrCtxt :: ContextElement -> TcM a -> TcM a
addErrCtxt msg = addErrCtxtM (\env -> return (env, msg))

addErrCtxtM :: (TidyEnv -> TcM (TidyEnv, ContextElement)) -> TcM a -> TcM a
addErrCtxtM ctxt = updCtxt (\ ctxts -> (False, ctxt) : ctxts)

addLandmarkErrCtxt :: ContextElement -> TcM a -> TcM a
addLandmarkErrCtxt msg = updCtxt (\ctxts -> (True, \env -> return (env,msg)) : ctxts)

-- Helper function for the above
updCtxt :: ([ErrCtxt] -> [ErrCtxt]) -> TcM a -> TcM a
updCtxt upd = updLclEnv (\ env@(TcLclEnv { tcl_ctxt = ctxt }) ->
                           env { tcl_ctxt = upd ctxt })

popErrCtxt :: TcM a -> TcM a
popErrCtxt = updCtxt (\ msgs -> case msgs of { [] -> []; (_ : ms) -> ms })

getCtLoc :: CtOrigin -> TcM CtLoc
getCtLoc origin
  = do { env <- getLclEnv
       ; return (CtLoc { ctl_origin = origin
                       , ctl_env = env
                       , ctl_depth = initialSubGoalDepth }) }

setCtLoc :: CtLoc -> TcM a -> TcM a
-- Set the SrcSpan and error context from the CtLoc
setCtLoc (CtLoc { ctl_env = lcl }) thing_inside
  = updLclEnv (\env -> env { tcl_loc   = tcl_loc lcl
                           , tcl_bndrs = tcl_bndrs lcl
                           , tcl_ctxt  = tcl_ctxt lcl })
              thing_inside

{-
************************************************************************
*                                                                      *
             Error message generation (type checker)
*                                                                      *
************************************************************************

    The addErrTc functions add an error message, but do not cause failure.
    The 'M' variants pass a TidyEnv that has already been used to
    tidy up the message; we then use it to tidy the context messages
-}

addErrTc :: TypeError -> TcM ()
addErrTc err_msg = do { env0 <- tcInitTidyEnv
                      ; addErrTcM (env0, err_msg) }

addErrsTc :: [TypeError] -> TcM ()
addErrsTc err_msgs = mapM_ addErrTc err_msgs

addErrTcM :: (TidyEnv, TypeError) -> TcM ()
addErrTcM (tidy_env, err_msg)
  = do { ctxt <- getErrCtxt ;
         loc  <- getSrcSpanM ;
         add_err_tcm tidy_env err_msg loc ctxt }

-- Return the error message, instead of reporting it straight away
mkErrTcM :: (TidyEnv, TypeError) -> TcM ErrMsg
mkErrTcM (tidy_env, err_msg)
  = do { ctxt <- getErrCtxt ;
         loc  <- getSrcSpanM ;
         err_info <- mkErrInfo tidy_env ctxt ;
         mkLongErrAt loc err_msg err_info }

-- The failWith functions add an error message and cause failure

failWithTc :: TypeError -> TcM a               -- Add an error message and fail
failWithTc err_msg
  = addErrTc err_msg >> failM

failWithTcM :: (TidyEnv, TypeError) -> TcM a   -- Add an error message and fail
failWithTcM local_and_msg
  = addErrTcM local_and_msg >> failM

checkTc :: Bool -> TypeError -> TcM ()         -- Check that the boolean is true
checkTc True  _   = return ()
checkTc False err = failWithTc err

--         Warnings have no 'M' variant, nor failure

-- | Display a warning if a condition is met.
warnTc :: WarnReason -> Bool -> MsgDoc -> TcM ()
warnTc reason warn_if_true warn_msg
  | warn_if_true = addWarnTc reason warn_msg
  | otherwise    = return ()

addWarnTc :: WarnReason -> MsgDoc -> TcM ()
addWarnTc reason msg = do { env0 <- tcInitTidyEnv
                   ; addWarnTcM reason (env0, msg) }

addWarnTcM :: WarnReason -> (TidyEnv, MsgDoc) -> TcM ()
addWarnTcM reason (env0, msg)
 = do { ctxt <- getErrCtxt ;
        err_info <- mkErrInfo env0 ctxt ;
        add_warn reason msg (vcat $ map ppr err_info) }

addWarn :: WarnReason -> MsgDoc -> TcRn ()
addWarn reason msg = add_warn reason msg empty

addWarnAt :: WarnReason -> SrcSpan -> MsgDoc -> TcRn ()
addWarnAt reason loc msg = add_warn_at reason loc msg empty

add_warn :: WarnReason -> MsgDoc -> MsgDoc -> TcRn ()
add_warn reason msg extra_info
  = do { loc <- getSrcSpanM
       ; add_warn_at reason loc msg extra_info }

add_warn_at :: WarnReason -> SrcSpan -> MsgDoc -> MsgDoc -> TcRn ()
add_warn_at reason loc msg extra_info
  = do { dflags <- getDynFlags ;
         printer <- getPrintUnqualified dflags ;
         let { warn = makeIntoWarning reason $
                        mkLongWarnMsg dflags loc printer msg extra_info } ;
         reportWarning warn }

tcInitTidyEnv :: TcM TidyEnv
tcInitTidyEnv
  = do  { lcl_env <- getLclEnv
        ; return (tcl_tidy lcl_env) }

{-
-----------------------------------
        Other helper functions
-}

add_err_tcm :: TidyEnv -> TypeError -> SrcSpan
            -> [ErrCtxt]
            -> TcM ()
add_err_tcm tidy_env err_msg loc ctxt
 = do { err_info <- mkErrInfo tidy_env ctxt ;
        addLongErrAt loc err_msg err_info }

mkErrInfo :: TidyEnv -> [ErrCtxt] -> TcM [ContextElement]
-- Tidy the error info, trimming excessive contexts
mkErrInfo env ctxts
--  | opt_PprStyle_Debug     -- In -dppr-debug style the output
--  = return empty           -- just becomes too voluminous
 | otherwise
 = go env ctxts
 where
   go :: TidyEnv -> [ErrCtxt] -> TcM [ContextElement]
   go _   [] = return []
   go env ((_is_landmark, ctxt) : ctxts) = do
     (env', msg) <- ctxt env
     msgs <- go env' ctxts
     return $ msg : msgs

     -- | is_landmark || n < mAX_CONTEXTS -- Too verbose || opt_PprStyle_Debug
     -- = do { (env', msg) <- ctxt env
     --      ; let n' = if is_landmark then n else n+1
     --      ; rest <- go n' env' ctxts
     --      ; return (ppr msg $$ rest) }
     -- | otherwise
     -- = go n env ctxts

mAX_CONTEXTS :: Int     -- No more than this number of non-landmark contexts
mAX_CONTEXTS = 3

-- debugTc is useful for monadic debugging code

debugTc :: TcM () -> TcM ()
debugTc thing
 | debugIsOn = thing
 | otherwise = return ()

{-
************************************************************************
*                                                                      *
             Type constraints
*                                                                      *
************************************************************************
-}

newTcEvBinds :: TcM EvBindsVar
newTcEvBinds = do { ref <- newTcRef emptyEvBindMap
                  ; uniq <- newUnique
                  ; return (EvBindsVar ref uniq) }

addTcEvBind :: EvBindsVar -> EvVar -> EvTerm -> TcM ()
-- Add a binding to the TcEvBinds by side effect
addTcEvBind (EvBindsVar ev_ref _) ev_id ev_tm
  = do { traceTc "addTcEvBind" $ vcat [ text "ev_id =" <+> ppr ev_id
                                      , text "ev_tm =" <+> ppr ev_tm ]
       ; bnds <- readTcRef ev_ref
       ; writeTcRef ev_ref (extendEvBinds bnds ev_id ev_tm) }

getTcEvBinds :: EvBindsVar -> TcM (Bag EvBind)
getTcEvBinds (EvBindsVar ev_ref _)
  = do { bnds <- readTcRef ev_ref
       ; return (evBindMapBinds bnds) }

chooseUniqueOccTc :: (OccSet -> OccName) -> TcM OccName
chooseUniqueOccTc fn =
  do { env <- getGblEnv
     ; let dfun_n_var = tcg_dfun_n env
     ; set <- readTcRef dfun_n_var
     ; let occ = fn set
     ; writeTcRef dfun_n_var (extendOccSet set occ)
     ; return occ }

getConstraintVar :: TcM (TcRef WantedConstraints)
getConstraintVar = do { env <- getLclEnv; return (tcl_lie env) }

setConstraintVar :: TcRef WantedConstraints -> TcM a -> TcM a
setConstraintVar lie_var = updLclEnv (\ env -> env { tcl_lie = lie_var })

emitConstraints :: WantedConstraints -> TcM ()
emitConstraints ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`andWC` ct) }

emitSimple :: Ct -> TcM ()
emitSimple ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addSimples` unitBag ct) }

emitSimples :: Cts -> TcM ()
emitSimples cts
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addSimples` cts) }

emitImplication :: Implication -> TcM ()
emitImplication ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addImplics` unitBag ct) }

emitImplications :: Bag Implication -> TcM ()
emitImplications ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addImplics` ct) }

emitInsoluble :: Ct -> TcM ()
emitInsoluble ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addInsols` unitBag ct) ;
         v <- readTcRef lie_var ;
         traceTc "emitInsoluble" (ppr v) }

tryCaptureConstraints :: TcM a -> TcM (Either IOEnvFailure a, WantedConstraints)
-- (captureConstraints_maybe m) runs m,
-- and returns the type constraints it generates
-- It never throws an exception; instead if thing_inside fails,
--   it returns Left exn and the insoluble constraints
tryCaptureConstraints thing_inside
  = do { lie_var <- newTcRef emptyWC
       ; mb_res <- tryM $
                   updLclEnv (\ env -> env { tcl_lie = lie_var }) $
                   thing_inside
       ; lie <- readTcRef lie_var

       -- See Note [Constraints and errors]
       ; let lie_to_keep = case mb_res of
                             Left {}  -> insolublesOnly lie
                             Right {} -> lie

       ; return (mb_res, lie_to_keep) }

captureConstraints :: TcM a -> TcM (a, WantedConstraints)
-- (captureConstraints m) runs m, and returns the type constraints it generates
captureConstraints thing_inside
  = do { (mb_res, lie) <- tryCaptureConstraints thing_inside

            -- See Note [Constraints and errors]
            -- If the thing_inside threw an exception, emit the insoluble
            -- constraints only (returned by tryCaptureConstraints)
            -- so that they are not lost
       ; case mb_res of
           Left _    -> do { emitConstraints lie; failM }
           Right res -> return (res, lie) }

captureTcLevel :: TcM a -> TcM (a, TcLevel)
captureTcLevel thing_inside
  = do { env <- getLclEnv
       ; let tclvl' = pushTcLevel (tcl_tclvl env)
       ; res <- setLclEnv (env { tcl_tclvl = tclvl' })
                thing_inside
       ; return (res, tclvl') }

-- | The name says it all. The returned TcLevel is the *inner* TcLevel.
pushLevelAndCaptureConstraints :: TcM a -> TcM (a, TcLevel, WantedConstraints)
pushLevelAndCaptureConstraints thing_inside
  = do { env <- getLclEnv
       ; let tclvl' = pushTcLevel (tcl_tclvl env)
       ; (res, lie) <- setLclEnv (env { tcl_tclvl = tclvl' }) $
                       captureConstraints thing_inside
       ; return (res, tclvl', lie) }

pushTcLevelM :: TcM a -> TcM a
pushTcLevelM thing_inside
  = do { env <- getLclEnv
       ; let tclvl' = pushTcLevel (tcl_tclvl env)
       ; setLclEnv (env { tcl_tclvl = tclvl' })
                   thing_inside }

pushTcLevelM2 :: TcM a -> TcM (a, TcLevel)
-- See Note [TcLevel assignment] in TcType
pushTcLevelM2 thing_inside
 = do { env <- getLclEnv
      ; let tclvl' = pushTcLevel (tcl_tclvl env)
      ; res <- setLclEnv (env { tcl_tclvl = tclvl' })
                         thing_inside
      ; return (res, tclvl') }

getTcLevel :: TcM TcLevel
getTcLevel = do { env <- getLclEnv
                     ; return (tcl_tclvl env) }

setTcLevel :: TcLevel -> TcM a -> TcM a
setTcLevel tclvl thing_inside
  = updLclEnv (\env -> env { tcl_tclvl = tclvl }) thing_inside

isTouchableTcM :: TcTyVar -> TcM Bool
isTouchableTcM tv
  = do { env <- getLclEnv
       ; return (isTouchableMetaTyVar (tcl_tclvl env) tv) }

getLclTypeEnv :: TcM TcTypeEnv
getLclTypeEnv = do { env <- getLclEnv; return (tcl_env env) }

setLclTypeEnv :: TcLclEnv -> TcM a -> TcM a
-- Set the local type envt, but do *not* disturb other fields,
-- notably the lie_var
setLclTypeEnv lcl_env thing_inside
  = updLclEnv upd thing_inside
  where
    upd env = env { tcl_env = tcl_env lcl_env,
                    tcl_tyvars = tcl_tyvars lcl_env }

traceTcConstraints :: String -> TcM ()
traceTcConstraints msg
  = do { lie_var <- getConstraintVar
       ; lie     <- readTcRef lie_var
       ; traceTc (msg ++ ": LIE:") (ppr lie)
       }

emitWildcardHoleConstraints :: [(Name, TcTyVar)] -> TcM ()
emitWildcardHoleConstraints wcs
  = do { ctLoc <- getCtLoc HoleOrigin
       ; forM_ wcs $ \(name, tv) -> do {
       ; let real_span = case nameSrcSpan name of
                           RealSrcSpan span  -> span
                           UnhelpfulSpan str -> pprPanic "emitWildcardHoleConstraints"
                                                      (ppr name <+> quotes (ftext str))
               -- Wildcards are defined locally, and so have RealSrcSpans
             ctLoc' = setCtLocSpan ctLoc real_span
             ty     = mkTyVarTy tv
             ev     = mkLocalId name ty
             can    = CHoleCan { cc_ev   = CtWanted ty ev ctLoc'
                               , cc_occ  = occName name
                               , cc_hole = TypeHole }
       ; emitInsoluble can } }

{- Note [Constraints and errors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this (Trac #12124):

  foo :: Maybe Int
  foo = return (case Left 3 of
                  Left -> 1  -- Hard error here!
                  _    -> 0)

The call to 'return' will generate a (Monad m) wanted constraint; but
then there'll be "hard error" (i.e. an exception in the TcM monad), from
the unsaturated Left constructor pattern.

We'll recover in tcPolyBinds, using recoverM.  But then the final
tcSimplifyTop will see that (Monad m) constraint, with 'm' utterly
un-filled-in, and will emit a misleading error message.

The underlying problem is that an exception interrupts the constraint
gathering process. Bottom line: if we have an exception, it's best
simply to discard any gathered constraints.  Hence in 'try_m' we
capture the constraints in a fresh variable, and only emit them into
the surrounding context if we exit normally.  If an exception is
raised, simply discard the collected constraints... we have a hard
error to report.  So this capture-the-emit dance isn't as stupid as it
looks :-).

However suppose we throw an exception inside an invocation of
captureConstraints, and discard all the constraints. Some of those
constraints might be "variable out of scope" Hole constraints, and that
might have been the actual original cause of the exception!  For
example (Trac #12529):
   f = p @ Int
Here 'p' is out of scope, so we get an insolube Hole constraint. But
the visible type application fails in the monad (thows an exception).
We must not discard the out-of-scope error.

So we /retain the insoluble constraints/ if there is an exception.
Hence:
  - insolublesOnly in tryCaptureConstraints
  - emitConstraints in the Left case of captureConstraints

Hover note that fresly-generated constraints like (Int ~ Bool), or
((a -> b) ~ Int) are all CNonCanonical, and hence won't be flagged as
insoluble.  The constraint solver does that.  So they'll be discarded.
That's probably ok; but see th/5358 as a not-so-good example:
   t1 :: Int
   t1 x = x   -- Manifestly wrong

   foo = $(...raises exception...)
We report the exception, but not the bug in t1.  Oh well.  Possible
solution: make TcUnify.uType spot manifestly-insoluble constraints.


************************************************************************
*                                                                      *
             Template Haskell context
*                                                                      *
************************************************************************
-}

recordThUse :: TcM ()
recordThUse = do { env <- getGblEnv; writeTcRef (tcg_th_used env) True }

recordThSpliceUse :: TcM ()
recordThSpliceUse = do { env <- getGblEnv; writeTcRef (tcg_th_splice_used env) True }

keepAlive :: Name -> TcRn ()     -- Record the name in the keep-alive set
keepAlive name
  = do { env <- getGblEnv
       ; traceRn "keep alive" (ppr name)
       ; updTcRef (tcg_keep env) (`extendNameSet` name) }

getStage :: TcM ThStage
getStage = do { env <- getLclEnv; return (tcl_th_ctxt env) }

getStageAndBindLevel :: Name -> TcRn (Maybe (TopLevelFlag, ThLevel, ThStage))
getStageAndBindLevel name
  = do { env <- getLclEnv;
       ; case lookupNameEnv (tcl_th_bndrs env) name of
           Nothing                  -> return Nothing
           Just (top_lvl, bind_lvl) -> return (Just (top_lvl, bind_lvl, tcl_th_ctxt env)) }

setStage :: ThStage -> TcM a -> TcRn a
setStage s = updLclEnv (\ env -> env { tcl_th_ctxt = s })

-- | Adds the given modFinalizers to the global environment and set them to use
-- the current local environment.
addModFinalizersWithLclEnv :: ThModFinalizers -> TcM ()
addModFinalizersWithLclEnv mod_finalizers
  = do lcl_env <- getLclEnv
       th_modfinalizers_var <- fmap tcg_th_modfinalizers getGblEnv
       updTcRef th_modfinalizers_var $ \fins ->
         setLclEnv lcl_env (runRemoteModFinalizers mod_finalizers)
         : fins

{-
************************************************************************
*                                                                      *
             Safe Haskell context
*                                                                      *
************************************************************************
-}

-- | Mark that safe inference has failed
recordUnsafeInfer :: TcM ()
recordUnsafeInfer = getGblEnv >>= \env -> writeTcRef (tcg_safeInfer env) False

-- | Figure out the final correct safe haskell mode
finalSafeMode :: DynFlags -> TcGblEnv -> IO SafeHaskellMode
finalSafeMode dflags tcg_env = do
    safeInf <- readIORef (tcg_safeInfer tcg_env)
    return $ case safeHaskell dflags of
        Sf_None | safeInferOn dflags && safeInf -> Sf_Safe
                | otherwise                     -> Sf_None
        s -> s

{-
************************************************************************
*                                                                      *
             Stuff for the renamer's local env
*                                                                      *
************************************************************************
-}

getLocalRdrEnv :: RnM LocalRdrEnv
getLocalRdrEnv = do { env <- getLclEnv; return (tcl_rdr env) }

setLocalRdrEnv :: LocalRdrEnv -> RnM a -> RnM a
setLocalRdrEnv rdr_env thing_inside
  = updLclEnv (\env -> env {tcl_rdr = rdr_env}) thing_inside

{-
************************************************************************
*                                                                      *
             Stuff for interface decls
*                                                                      *
************************************************************************
-}

mkIfLclEnv :: Module -> SDoc -> Bool -> IfLclEnv
mkIfLclEnv mod loc boot = IfLclEnv { if_mod     = mod,
                                     if_loc     = loc,
                                     if_boot    = boot,
                                     if_tv_env  = emptyUFM,
                                     if_nsubst  = Nothing,
                                     if_id_env  = emptyUFM }

-- | Run an 'IfG' (top-level interface monad) computation inside an existing
-- 'TcRn' (typecheck-renaming monad) computation by initializing an 'IfGblEnv'
-- based on 'TcGblEnv'.
initIfaceTcRn :: IfG a -> TcRn a
initIfaceTcRn thing_inside
  = do  { tcg_env <- getGblEnv
        ; dflags <- getDynFlags
              ; let mod = tcg_semantic_mod tcg_env
                    -- When we are instantiating a signature, we DEFINITELY
                    -- do not want to knot tie.
                    is_instantiate = unitIdIsDefinite (thisPackage dflags) &&
                                     not (null (thisUnitIdInsts dflags))
        ; let { if_env = IfGblEnv {
                              if_rec_types =
                                  if is_instantiate
                                      then Nothing
                                      else Just (mod, get_type_env)
                         }
              ; get_type_env = readTcRef (tcg_type_env_var tcg_env) }
        ; setEnvs (if_env, ()) thing_inside }

-- Used when sucking in a ModIface into a ModDetails to put in
-- the HPT.  Notably, unlike initIfaceCheck, this does NOT use
-- hsc_type_env_var (since we're not actually going to typecheck,
-- so this variable will never get updated!)
initIfaceLoad :: HscEnv -> IfG a -> IO a
initIfaceLoad hsc_env do_this
 = do let gbl_env = IfGblEnv {
                        -- if_doc = text "initIfaceLoad",
                        if_rec_types = Nothing
                    }
      initTcRnIf 'i' hsc_env gbl_env () do_this

initIfaceCheck :: HscEnv -> IfG a -> IO a
-- Used when checking the up-to-date-ness of the old Iface
-- Initialise the environment with no useful info at all
initIfaceCheck hsc_env do_this
 = do let rec_types = case hsc_type_env_var hsc_env of
                         Just (mod,var) -> Just (mod, readTcRef var)
                         Nothing        -> Nothing
          gbl_env = IfGblEnv { if_rec_types = rec_types }
      initTcRnIf 'i' hsc_env gbl_env () do_this

initIfaceLcl :: Module -> SDoc -> Bool -> IfL a -> IfM lcl a
initIfaceLcl mod loc_doc hi_boot_file thing_inside
  = setLclEnv (mkIfLclEnv mod loc_doc hi_boot_file) thing_inside

-- | Initialize interface typechecking, but with a 'NameShape'
-- to apply when typechecking top-level 'OccName's (see
-- 'lookupIfaceTop')
initIfaceLclWithSubst :: Module -> SDoc -> Bool -> NameShape -> IfL a -> IfM lcl a
initIfaceLclWithSubst mod loc_doc hi_boot_file nsubst thing_inside
  = setLclEnv ((mkIfLclEnv mod loc_doc hi_boot_file) { if_nsubst = Just nsubst }) thing_inside

getIfModule :: IfL Module
getIfModule = do { env <- getLclEnv; return (if_mod env) }

--------------------
failIfM :: MsgDoc -> IfL a
-- The Iface monad doesn't have a place to accumulate errors, so we
-- just fall over fast if one happens; it "shouldnt happen".
-- We use IfL here so that we can get context info out of the local env
failIfM msg
  = do  { env <- getLclEnv
        ; let full_msg = (if_loc env <> colon) $$ nest 2 msg
        ; dflags <- getDynFlags
        ; liftIO (putLogMsg dflags NoReason SevFatal
                    noSrcSpan (defaultErrStyle dflags) full_msg)
        ; failM }

--------------------
forkM_maybe :: SDoc -> IfL a -> IfL (Maybe a)
-- Run thing_inside in an interleaved thread.
-- It shares everything with the parent thread, so this is DANGEROUS.
--
-- It returns Nothing if the computation fails
--
-- It's used for lazily type-checking interface
-- signatures, which is pretty benign

forkM_maybe doc thing_inside
 -- NB: Don't share the mutable env_us with the interleaved thread since env_us
 --     does not get updated atomically (e.g. in newUnique and newUniqueSupply).
 = do { child_us <- newUniqueSupply
      ; child_env_us <- newMutVar child_us
        -- see Note [Masking exceptions in forkM_maybe]
      ; unsafeInterleaveM $ uninterruptibleMaskM_ $ updEnv (\env -> env { env_us = child_env_us }) $
        do { traceIf (text "Starting fork {" <+> doc)
           ; mb_res <- tryM $
                       updLclEnv (\env -> env { if_loc = if_loc env $$ doc }) $
                       thing_inside
           ; case mb_res of
                Right r  -> do  { traceIf (text "} ending fork" <+> doc)
                                ; return (Just r) }
                Left exn -> do {

                    -- Bleat about errors in the forked thread, if -ddump-if-trace is on
                    -- Otherwise we silently discard errors. Errors can legitimately
                    -- happen when compiling interface signatures (see tcInterfaceSigs)
                      whenDOptM Opt_D_dump_if_trace $ do
                          dflags <- getDynFlags
                          let msg = hang (text "forkM failed:" <+> doc)
                                       2 (text (show exn))
                          liftIO $ putLogMsg dflags
                                             NoReason
                                             SevFatal
                                             noSrcSpan
                                             (defaultErrStyle dflags)
                                             msg

                    ; traceIf (text "} ending fork (badly)" <+> doc)
                    ; return Nothing }
        }}

forkM :: SDoc -> IfL a -> IfL a
forkM doc thing_inside
 = do   { mb_res <- forkM_maybe doc thing_inside
        ; return (case mb_res of
                        Nothing -> pgmError "Cannot continue after interface file error"
                                   -- pprPanic "forkM" doc
                        Just r  -> r) }

{-
Note [Masking exceptions in forkM_maybe]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When using GHC-as-API it must be possible to interrupt snippets of code
executed using runStmt (#1381). Since commit 02c4ab04 this is almost possible
by throwing an asynchronous interrupt to the GHC thread. However, there is a
subtle problem: runStmt first typechecks the code before running it, and the
exception might interrupt the type checker rather than the code. Moreover, the
typechecker might be inside an unsafeInterleaveIO (through forkM_maybe), and
more importantly might be inside an exception handler inside that
unsafeInterleaveIO. If that is the case, the exception handler will rethrow the
asynchronous exception as a synchronous exception, and the exception will end
up as the value of the unsafeInterleaveIO thunk (see #8006 for a detailed
discussion).  We don't currently know a general solution to this problem, but
we can use uninterruptibleMask_ to avoid the situation.
-}
