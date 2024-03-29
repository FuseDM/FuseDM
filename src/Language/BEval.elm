module Language.BEval exposing (..)

import Utils exposing (lookup)
import Language.Utils exposing (..)
import Language.UtilsFD exposing (..)
import Language.FEval exposing (..)
import Language.DEval exposing (..)
import Language.Syntax exposing (..)
import Language.Fusion exposing (..)
import Printer.Exp exposing (..)
import Printer.Value exposing (printDelta)

beval : Env -> Exp -> Delta -> ST -> (Env, (Exp, List (String, Exp)), ST)
beval env exp delta st =
    case (exp, delta) of
        (_, DId)     -> (env, exp |> empFunList, st)
        (_, DRewr p) ->
            let lastSP = getLastSpaces exp in
            (env, param2Exp p |> setLastSpaces lastSP |> empFunList, st)

        (_, DAbst (AVar s)) ->
            case lookup s st of
                Just (env1, _) ->
                    if env1 == env
                    then
                        let lastSP = getLastSpaces exp in
                        (env, EVar [lastSP] s  |> empFunList, updateST st s exp)
                    else
                        (env, exp |> empFunList, st)
                
                Nothing        -> ([], EError "Error 20" |> empFunList, [])

        (EFloat ws f, DAdd (AFloat f1)) -> (env, EFloat ws (f + f1) |> empFunList, st)
        (EFloat ws f, DMul (AFloat f1)) -> (env, EFloat ws (f * f1) |> empFunList, st)

        (ENil ws,     DInsert 0 p) -> (env, ECons [""] (param2Exp p) (ENil ws)     |> empFunList, st)
        (EEmpList ws, DInsert 0 p) -> (env, EList ws   (param2Exp p) (EEmpList []) |> empFunList, st)

        (ENil _,     DGen _ _ _) -> (env, exp |> empFunList, st)
        (EEmpList _, DGen _ _ _) -> (env, exp |> empFunList, st)

        (ENil _,     DMem _ ANil) -> (env, exp |> empFunList, st)
        (EEmpList _, DMem _ ANil) -> (env, exp |> empFunList, st)

        (EVar _ x, _) ->
            case lookup x env of
                Just (v, od) ->
                    case fixCheck v delta of
                        Just d  -> (updateDelta env x (DCom od d), exp         |> empFunList, st)
                        Nothing -> ([],  EError "Recursion Conflict" |> empFunList, [])

                Nothing ->
                    ([], EError "Error 37" |> empFunList, [])

        (ELam ws _ _, DClosure env1 p1 e1) -> (env1, ELam ws p1 e1 |> empFunList, st)

        (EApp ws e1 e2, _) ->
            case feval env e1 of
                VClosure envf p ef ->
                    let
                        envm_res =
                            case e2 of
                                EFix _ e2_ -> match p (VFix env e2_)
                                _          -> feval env e2 |> match p
                    in
                    case envm_res of
                        Just envm ->
                            let
                                -- TODO: check if this is correct for ST
                                (env_, (ef_, fl1), st_) =
                                    beval (envm ++ envf) ef delta st
                                
                                (envm_, envf_) =
                                    ( List.take (List.length envm) env_
                                    , List.drop (List.length envm) env_)
                                
                                (env1, (new_e1, fl2), _) = beval env e1 (DClosure envf_ p ef_) []
                                (env2, (new_e2, fl3), _) = beval env e2 (substDelta p envm_) []

                                (fv1, fv2) =
                                    (freeVars e1, freeVars e2)

                                flTotal = fl1 ++ fl2 ++ fl3
                            in
                            if new_e1 == EError "Recursion Conflict"
                            || new_e1 == EError "Fusion Failed"
                            || new_e2 == EError "Fusion Failed"
                            then
                                (env, fuse delta exp, st)
                            else
                                case ws of
                                    "EQ" :: _ ->
                                        case two_wayMerge fv1 fv2 env1 env2 of
                                            (new_env, [], [])       -> 
                                                ( new_env
                                                , EApp ws new_e1 new_e2 |> fuseFunList flTotal |> empFunList
                                                , st_)
                                            (new_env, denv1, denv2) ->
                                                let
                                                    (fusedE1, fl4) = fuseEnv denv1 new_e1
                                                    (fusedE2, fl5) = fuseEnv denv2 new_e2
                                                in
                                                if  fusedE1 == EError "Fusion Failed" ||
                                                    fusedE2 == EError "Fusion Failed"
                                                then
                                                    (env, fuse delta exp, st)
                                                else
                                                    ( new_env
                                                    , EApp ws fusedE1 fusedE2 |> fuseFunList (flTotal ++ fl4 ++ fl5) |> empFunList
                                                    , st_)
                                    _         ->
                                        case two_wayMerge fv1 fv2 env1 env2 of
                                            (new_env, [], [])       -> (new_env, (EApp ws new_e1 new_e2, flTotal), st_)
                                            (new_env, denv1, denv2) ->
                                                let
                                                    (fusedE1, fl4) = fuseEnv denv1 new_e1
                                                    (fusedE2, fl5) = fuseEnv denv2 new_e2
                                                in
                                                if  fusedE1 == EError "Fusion Failed" ||
                                                    fusedE2 == EError "Fusion Failed"
                                                then
                                                    (env, fuse delta exp, st)
                                                else
                                                    (new_env, (EApp ws fusedE1 fusedE2, flTotal ++ fl4 ++ fl5), st_)
                        
                        Nothing -> ([], EError "Error 30" |> empFunList, [])
                
                _ -> ([], EError "Error 31" |> empFunList, [])

        (EFix ws1 _, DFix env1 e1) -> (env1, EFix ws1 e1 |> empFunList, st)

        (ECase ws e1 bs, _) ->
            let
                v1  = feval env e1        
                res = matchBranch v1 bs 0
            in
            case res.ei of
                EError info -> ([], EError info |> empFunList, [])
                _           ->
                    -- TODO: check if this is correct for ST
                    case beval (res.envm ++ env) res.ei delta st of
                        (env_, (ei_, fl1), st_) ->
                            let
                                (envm_, env2) =
                                    ( List.take (List.length res.envm) env_
                                    , List.drop (List.length res.envm) env_)

                                (env1, (new_e1, fl2), _) = beval env e1 (substDelta res.pi envm_) []
                                (fv1, fv2)               = (freeVars e1, freeVars res.ei)
                            in
                            if new_e1 == EError "Fusion Failed"
                            || ei_    == EError "Fusion Failed" 
                            then
                                (env, fuse delta exp, st)
                            else
                                case two_wayMerge fv1 fv2 env1 env2 of
                                    (new_env, [], [])      ->
                                        ( new_env
                                        , (updateBranch bs 0 res.choice ei_ 
                                            |> Tuple.first
                                            |> ECase ws new_e1
                                            , fl1 ++ fl2)
                                        , st_)
                                    
                                    (new_env, denv1, denv2) ->
                                        let
                                            (fusedE1, fl3) = fuseEnv denv1 new_e1
                                            (fusedEi, fl4) = fuseEnv denv2 ei_
                                        in
                                        if  fusedE1 == EError "Fusion Failed" ||
                                            fusedEi == EError "Fusion Failed"
                                        then
                                            (env, fuse delta exp, st)
                                        else
                                            (new_env
                                            , (updateBranch bs 0 res.choice fusedEi
                                                |> Tuple.first
                                                |> ECase ws fusedE1
                                                , fl1 ++ fl2 ++ fl3 ++ fl4)
                                            , st_)

        (ECons ws e1 e2, DCons d1 d2) ->
            let
                (env1, (new_e1, fl1), st1) = beval env e1 d1 st             
                (env2, (new_e2, fl2), st2) = beval env e2 d2 st

                new_ST = mergeST st1 st2
            in
            if new_e1 == EError "Fusion Failed"
            || new_e2 == EError "Fusion Failed" 
            then
                (env, fuse delta exp, st)
            else
            case two_wayMerge (freeVars e1) (freeVars e2) env1 env2 of
                (new_env, [], [])       -> (new_env, (ECons ws new_e1 new_e2, fl1 ++ fl2), new_ST)
                (new_env, denv1, denv2) ->
                    let
                        (fusedE1, fl3) = fuseEnv denv1 new_e1
                        (fusedE2, fl4) = fuseEnv denv2 new_e2
                    in
                    if  fusedE1 == EError "Fusion Failed" ||
                        fusedE2 == EError "Fusion Failed"
                    then
                        (env, fuse delta exp, st)
                    else
                        (new_env, (ECons ws fusedE1 fusedE2, fl1 ++ fl2 ++ fl3 ++ fl4), new_ST)

        (ECons ws e1 e2, DInsert n p) ->
            if n == 0 
            then
                (env, ECons ws (param2Exp p) exp |> empFunList, st)
            else
                let
                    (env2, (new_e2, fl1), st_) = beval env e2 (DInsert (n - 1) p) st
                in
                if new_e2 == EError "Fusion Failed" 
                then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                (new_env, [], [])   -> (new_env, (ECons ws e1 new_e2, fl1), st_)
                (new_env, _, denv2) ->
                    let
                        (fusedE2, fl2) = fuseEnv denv2 new_e2
                    in
                    if  fusedE2 == EError "Fusion Failed"
                    then
                        (env, fuse delta exp, st)
                    else
                        (new_env, (ECons ws e1 fusedE2, fl1 ++ fl2), st_)

        (ECons ws e1 e2, DDelete n) ->
            if n == 0 then
                (env, e2 |> empFunList, st)
            else
                let
                    (env2, (new_e2, fl1), st_) = beval env e2 (DDelete (n - 1)) st
                in
                if new_e2 == EError "Fusion Failed" 
                then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                (new_env, [], [])   -> (new_env, (ECons ws e1 new_e2, fl1), st_)
                (new_env, _, denv2) ->
                    let
                        (fusedE2, fl2) = fuseEnv denv2 new_e2
                    in
                    if  fusedE2 == EError "Fusion Failed"
                    then
                        (env, fuse delta exp, st)
                    else
                        (new_env, (ECons ws e1 fusedE2, fl1 ++ fl2), st_)
        
        (ECons ws e1 e2, DCopy n) ->
            if n == 0 then
                (env, ECons ws e1 (ECons ws e1 e2) |> empFunList, st)
            else
                let
                    (env2, (new_e2, fl1), st_) = beval env e2 (DCopy (n - 1)) st
                in
                if new_e2 == EError "Fusion Failed" 
                then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                    (new_env, [], [])   -> (new_env, (ECons ws e1 new_e2, fl1), st_)
                    (new_env, _, denv2) ->
                        let
                            (fusedE2, fl2) = fuseEnv denv2 new_e2
                        in
                        if  fusedE2 == EError "Fusion Failed"
                        then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (ECons ws e1 fusedE2, fl1 ++ fl2), st_)
        
        (ECons ws e1 e2, DModify n d) ->
            if n == 0 
            then
                let
                    (env1, (new_e1, fl1), st_) = beval env e1 d st
                in
                if new_e1 == EError "Fusion Failed" then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env1 env of
                    (new_env, [], [])   -> (new_env, (ECons ws new_e1 e2, fl1), st_)
                    (new_env, denv1, _) ->
                        let
                            (fusedE1, fl2) = fuseEnv denv1 new_e1
                        in
                        if  fusedE1 == EError "Fusion Failed"
                        then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (ECons ws fusedE1 e2, fl1 ++ fl2), st_)
            else
                let
                    (env2, (new_e2, fl1), st_) =
                        beval env e2 (DModify (n - 1) d) st
                in
                if new_e2 == EError "Fusion Failed"
                then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                    (new_env, [], [])   -> (new_env, (ECons ws e1 new_e2, fl1), st_)
                    (new_env, _, denv2) ->
                        let
                            (fusedE2, fl2) = fuseEnv denv2 new_e2
                        in
                        if  fusedE2 == EError "Fusion Failed"
                        then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (ECons ws e1 fusedE2, fl1 ++ fl2), st_)
        
        (ECons ws e1 e2, DGen next df p) ->
            case feval env (EApp [] next (p |> param2Exp)) of
                VTuple v1 v2 ->
                    let
                        d1 = v1 |> value2Param |> DApp df |> deval [] 
                        d2 = v2 |> value2Param |> DGen next df
                        
                        (env1, (new_e1, fl1), st1) = beval env e1 d1 st
                        (env2, (new_e2, fl2), st2) = beval env e2 d2 st

                        new_ST = mergeST st1 st2
                    in
                    if new_e1 == EError "Fusion Failed"
                    || new_e2 == EError "Fusion Failed" 
                    then
                        (env, fuse delta exp, st)
                    else
                    case two_wayMerge (freeVars e1) (freeVars e2) env1 env2 of
                        (new_env, [], [])       -> (new_env, (ECons ws e1 new_e2, fl1 ++ fl2), new_ST)
                        (new_env, denv1, denv2) ->
                            let
                                (fusedE1, fl3) = fuseEnv denv1 new_e1
                                (fusedE2, fl4) = fuseEnv denv2 new_e2
                            in
                            if  fusedE1 == EError "Fusion Failed" ||
                                fusedE2 == EError "Fusion Failed"
                            then
                                (env, fuse delta exp, st)
                            else
                                (new_env, (ECons ws fusedE1 fusedE2, fl1 ++ fl2 ++ fl3 ++ fl4), new_ST)

                _ -> ([], EError "Error 32" |> empFunList, [])

        (ECons ws e1 e2, DMem s (ACons a1 a2)) ->
            let
                (env_, (e2_, _), st_) =
                    beval env e2 (DMem s a2) st
            in
            case a1 of
                ATrue -> case lookup s st_ of
                            Just (_, ls) -> (env_, e2_ |> empFunList, updateST st_ s (EList [""] e1 ls))
                            _            -> ([], EError "Error 01" |> empFunList, [])

                AFalse -> (env_, ECons ws e1 e2_ |> empFunList, st_)
                _      -> ([], EError "Error 02" |> empFunList, [])
        
        (EList ws e1 e2, DCons d1 d2) ->
            let
                (env1, (new_e1, fl1), st1) = beval env e1 d1 st
                (env2, (new_e2, fl2), st2) = beval env e2 d2 st

                new_ST = mergeST st1 st2
            in
            if new_e1 == EError "Fusion Failed"
            || new_e2 == EError "Fusion Failed" 
            then
                (env, fuse delta exp, st)
            else
            case two_wayMerge (freeVars e1) (freeVars e2) env1 env2 of
                (new_env, [], [])       -> (new_env, (EList ws new_e1 new_e2, fl1 ++ fl2), new_ST)
                (new_env, denv1, denv2) ->
                    let
                        (fusedE1, fl3) = fuseEnv denv1 new_e1
                        (fusedE2, fl4) = fuseEnv denv2 new_e2
                    in
                    if new_e1 == EError "Fusion Failed"
                    || new_e2 == EError "Fusion Failed" 
                    then
                        (env, fuse delta exp, st)
                    else
                        (new_env, (EList ws fusedE1 fusedE2, fl1 ++ fl2 ++ fl3 ++ fl4), new_ST)

        (EList ws e1 e2, DInsert n p) ->
            if n == 0 
            then
                (env, EList ws (param2Exp p) exp |> empFunList, st)
            else
                let
                    (env2, (new_e2, fl1), st_) = beval env e2 (DInsert (n - 1) p) st
                in
                if new_e2 == EError "Fusion Failed" 
                then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                    (new_env, [], [])   -> (new_env, (EList ws e1 new_e2, fl1), st_)
                    (new_env, _, denv2) ->
                        let
                            (fusedE2, fl2) = fuseEnv denv2 new_e2
                        in
                        if fusedE2 == EError "Fusion Failed" 
                        then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (EList ws e1 fusedE2, fl1 ++ fl2), st_)

        (EList ws e1 e2, DDelete n) ->
            if n == 0 
            then
                case ws of
                    _::[] -> (env, e2 |> empFunList, st)
                    _     ->
                        case e2 of
                            EList _ e21 e22 -> (env, EList ws e21 e22  |> empFunList, st)
                            EEmpList _      -> (env, EEmpList ["", ""] |> empFunList, st)
                            _               -> (env, EError "Error 03" |> empFunList, st)
            else
                let
                    (env2, (new_e2, fl1), st_) = beval env e2 (DDelete (n - 1)) st
                in
                if new_e2 == EError "Fusion Failed" 
                then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                    (new_env, [], [])   -> (new_env, (EList ws e1 new_e2, fl1), st_)
                    (new_env, _, denv2) ->
                        let
                            (fusedE2, fl2) = fuseEnv denv2 new_e2
                        in
                        if fusedE2 == EError "Fusion Failed"
                        then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (EList ws e1 fusedE2, fl1 ++ fl2), st_)

        (EList ws e1 e2, DCopy n) ->
            if n == 0 
            then
                case ws of
                    _::[] -> (env, EList ws e1 (EList ws e1 e2)    |> empFunList, st)
                    _     -> (env, EList ws e1 (EList [" "] e1 e2) |> empFunList, st)
            else
                let
                    (env2, (new_e2, fl1), st_) = beval env e2 (DCopy (n - 1)) st
                in
                if new_e2 == EError "Fusion Failed" 
                then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                    (new_env, [], [])   -> (new_env, (EList ws e1 new_e2, fl1), st_)
                    (new_env, _, denv2) ->
                        let
                            (fusedE2, fl2) = fuseEnv denv2 new_e2
                        in
                        if fusedE2 == EError "Fusion Failed"
                        then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (EList ws e1 fusedE2, fl1 ++ fl2), st_)

        (EList ws e1 e2, DModify n d) ->
            if n == 0 
            then
                let
                    (env1, (new_e1, fl1), st_) = beval env e1 d st
                in
                if new_e1 == EError "Fusion Failed" then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env1 env of
                    (new_env, [], [])   -> (new_env, (EList ws new_e1 e2, fl1), st_)
                    (new_env, denv1, _) ->
                        let
                            (fusedE1, fl2) = fuseEnv denv1 new_e1
                        in
                        if fusedE1 == EError "Fusion Failed" then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (EList ws fusedE1 e2, fl1 ++ fl2), st_)
            else
                let
                    (env2, (new_e2, fl1), st_) = beval env e2 (DModify (n - 1) d) st
                in
                if new_e2 == EError "Fusion Failed" then
                    (env, fuse delta exp, st)
                else
                case two_wayMerge (freeVars e1) (freeVars e2) env env2 of
                    (new_env, [], [])   -> (new_env, (EList ws e1 new_e2, fl1), st_)
                    (new_env, _, denv2) ->
                        let
                            (fusedE2, fl2) = fuseEnv denv2 new_e2
                        in
                        if fusedE2 == EError "Fusion Failed" then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (EList ws e1 fusedE2, fl1 ++ fl2), st_)
        
        (EList ws e1 e2, DGen next df p) ->
            case feval env (EApp [] next (p |> param2Exp)) of
                VTuple v1 v2 ->
                    let
                        d1 =  v1 |> value2Param |> DApp df |> deval []
                        d2 =  v2 |> value2Param |> DGen next df
                        
                        (env1, (new_e1, fl1), st1) = beval env e1 d1 st               
                        (env2, (new_e2, fl2), st2) = beval env e2 d2 st

                        new_ST = mergeST st1 st2
                    in
                    if new_e1 == EError "Fusion Failed"
                    || new_e2 == EError "Fusion Failed" 
                    then
                        (env, fuse delta exp, st)
                    else
                    case two_wayMerge (freeVars e1) (freeVars e2) env1 env2 of
                        (new_env, [], [])       -> (new_env, (EList ws new_e1 new_e2, fl1 ++ fl2), new_ST)
                        (new_env, denv1, denv2) ->
                            let
                                (fusedE1, fl3) = fuseEnv denv1 new_e1
                                (fusedE2, fl4) = fuseEnv denv2 new_e2
                            in
                            if fusedE1 == EError "Fusion Failed"
                            || fusedE2 == EError "Fusion Failed"
                            then
                                (env, fuse delta exp, st)
                            else
                                (new_env, (EList ws fusedE1 fusedE2, fl1 ++ fl2 ++ fl3 ++ fl4), new_ST)

                _ -> ([], EError "Error 33" |> empFunList, [])

        (EList ws e1 e2, DMem s (ACons a1 a2)) ->
            let
                (env_, (e2_, _), st_) =
                    beval env e2 (DMem s a2) st
            in
            case a1 of
                ATrue -> case lookup s st_ of
                            Just (_, ls) -> (env_, e2_ |> empFunList, updateST st_ s (EList [""] e1 ls))
                            _            -> ([], EError "Error 04" |> empFunList, [])

                AFalse -> (env_, EList ws e1 e2_ |> empFunList, st_)
                _      -> ([], EError "Error 34" |> empFunList, [])
        
        (ETuple ws e1 e2, DTuple d1 d2) ->
            let
                (env1, (new_e1, fl1), st1) = beval env e1 d1 st
                (env2, (new_e2, fl2), st2) = beval env e2 d2 st

                new_ST = mergeST st1 st2
            in
            if new_e1 == EError "Fusion Failed"
            || new_e2 == EError "Fusion Failed" 
            then
                (env, fuse delta exp, st)
            else
            case two_wayMerge (freeVars e1) (freeVars e2) env1 env2 of
                (new_env, [], [])       -> (new_env, (ETuple ws new_e1 new_e2, fl1 ++ fl2), new_ST)
                (new_env, denv1, denv2) ->
                    let
                        (fusedE1, fl3) = fuseEnv denv1 new_e1
                        (fusedE2, fl4) = fuseEnv denv2 new_e2
                    in
                    if fusedE1 == EError "Fusion Failed"
                    || fusedE2 == EError "Fusion Failed"
                    then
                        (env, fuse delta exp, st)
                    else
                        (new_env, (ETuple ws fusedE1 fusedE2, fl1 ++ fl2 ++ fl3 ++ fl4), new_ST)

        (EParens ws e1, _) ->
            let
                (env1, (new_e1, fl), st_) = beval env e1 delta st
            in
            if new_e1 == EError "Fusion Failed" 
            then (env,  EError "Fusion Failed" |> empFunList, st_)
            else (env1, (EParens ws new_e1, fl),              st_)

        (EBPrim ws Add e1 e2, DAdd _) ->
            let
                (env1, (new_e1, fl1), _) =
                    beval env e1 delta []
            
                (fv1, fv2) =
                    (freeVars e1, freeVars e2)
            in
            case two_wayMerge fv1 fv2 env1 env of
                    (new_env, [], [])   -> (new_env, (EBPrim ws Add new_e1 e2, fl1), st)
                    (new_env, denv1, _) ->
                        let
                            (fusedE1, fl2) = fuseEnv denv1 new_e1
                        in
                        if fusedE1 == EError "Fusion Failed"
                        then
                            (env, fuse delta exp, st)
                        else
                            (new_env, (EBPrim ws Add fusedE1 e2, fl1 ++ fl2), st)
        
        (EBPrim ws Mul e1 e2, DAdd (AFloat f)) ->
            case feval env e2 of
                VFloat f2 ->
                    let
                        (env1, (new_e1, fl1), _) =
                            beval env e1 ((f / f2 |> AFloat) |> DAdd) []

                        (fv1, fv2) =
                            (freeVars e1, freeVars e2)
                    in
                    case two_wayMerge fv1 fv2 env1 env of
                        (new_env, [], [])   -> (new_env, (EBPrim ws Mul new_e1 e2, fl1), st)
                        (new_env, denv1, _) ->
                            let
                                (fusedE1, fl2) = fuseEnv denv1 new_e1
                            in
                            if fusedE1 == EError "Fusion Failed"
                            then
                                (env, fuse delta exp, st)
                            else
                                (new_env, (EBPrim ws Mul fusedE1 e2, fl1 ++ fl2), st)

                _ ->
                    ([], EError "Error 35" |> empFunList, [])

        (EBPrim ws Add e1 e2, DMul (AFloat f)) ->
            case (feval env exp, feval env e1, feval env e2) of
                (VFloat sum, VFloat f1, VFloat f2) ->
                    let
                        delta1 =
                            (f * sum - f2) / f1 
                            |> AFloat 
                            |> DMul
                        
                        (env1, (new_e1, fl1), _) =
                            beval env e1 delta1 []
                        
                        (fv1, fv2) =
                            (freeVars e1, freeVars e2)
                    in
                    case two_wayMerge fv1 fv2 env1 env of
                        (new_env, [], [])    -> (new_env, (EBPrim ws Add new_e1 e2, fl1), st)
                        (new_env, denv1, _)  ->
                            let
                                (fusedE1, fl2) = fuseEnv denv1 new_e1
                            in
                            if fusedE1 == EError "Fusion Failed" 
                            then
                                (env, fuse delta exp, st)
                            else
                                (new_env, (EBPrim ws Add fusedE1 e2, fl1 ++ fl2), st)
                
                _ ->
                    ([], EError "Error 36" |> empFunList, st)
                        
        (EBPrim ws Mul e1 e2, DMul _) ->
            let
                (env1, (new_e1, fl1), _) =
                    beval env e1 delta []

                (fv1, fv2) =
                    (freeVars e1, freeVars e2)
            in
            case two_wayMerge fv1 fv2 env1 env of
                (new_env, [], [])   -> (new_env, (EBPrim ws Mul new_e1 e2, fl1), st)
                (new_env, denv1, _) ->
                    let
                        (fusedE1, fl2) = fuseEnv denv1 new_e1
                    in
                    if fusedE1 == EError "Fusion Failed" 
                    then
                        (env, fuse delta exp, st)
                    else
                        (new_env, (EBPrim ws Mul fusedE1 e2, fl1 ++ fl2), st)
        
        (EUPrim ws Neg e1, DAdd (AFloat f)) ->
            let
                (env1, (new_e1, fl), _) =
                    beval env e1 (AFloat -f |> DAdd) []
            in
                (env1, (EUPrim ws Neg new_e1, fl), st)
        
        (EUPrim ws Neg e1, DMul _) ->
            let
                (env1, (new_e1, fl), _) =
                    beval env e1 delta []
            in
                (env1, (EUPrim ws Neg new_e1, fl), st)

        (EUnwrap ws e,  _) ->
            let
                (env1, (new_e, fl), st_) =
                    beval env e (DMap delta) st
            in
                (env1, (EUnwrap ws new_e, fl), st_)
        
        (EMap ws e1 e2, DMap d) ->
            case feval env e1 of
                VClosure envf p ef ->
                    case feval env e2 of
                        VGraphic _ v ->
                            case match p v of
                            Just envm ->
                                let
                                    (env_, (ef_, fl1), st_) =
                                        beval (envm ++ envf) ef d st
                                    
                                    (envm_, envf_) =
                                        ( List.take (List.length envm) env_
                                        , List.drop (List.length envm) env_)
                                    
                                    _ = Debug.log "e2" (print e2)
                                    (env1, (new_e1, fl2), _) = beval env e1 (DClosure envf_ p ef_) []
                                    (env2, (new_e2, fl3), _) = beval env e2 (substDelta p envm_ |> DMap) []

                                    (fv1, fv2) =
                                        (freeVars e1, freeVars e2)

                                    flTotal = fl1 ++ fl2 ++ fl3
                                in
                                if new_e1 == EError "Recursion Conflict"
                                || new_e1 == EError "Fusion Failed"
                                || new_e2 == EError "Fusion Failed"
                                then
                                    (env, fuse delta exp, st)
                                else
                                case two_wayMerge fv1 fv2 env1 env2 of
                                    (new_env, [], [])       -> (new_env, (EMap ws new_e1 new_e2, flTotal), st_)
                                    (new_env, denv1, denv2) ->
                                        let
                                            (fusedE1, fl4) = fuseEnv denv1 new_e1
                                            (fusedE2, fl5) = fuseEnv denv2 new_e2
                                        in
                                        if fusedE1 == EError "Fusion Failed"
                                        || fusedE2 == EError "Fusion Failed"
                                        then
                                            (env, fuse delta exp, st)
                                        else
                                            (new_env, (EMap ws fusedE1 fusedE2, flTotal ++ fl4 ++ fl5), st_)
                
                            Nothing -> ([], EError "Error 50" |> empFunList, [])
                        
                        _ -> ([], EError ""|> empFunList, [])
                
                _ -> ([], EError "Error 51" |> empFunList, [])

        (EGraphic ws s e, DMap d) ->
            let
                (env1, (new_e, fl), st_) = beval env e d st
                _ = Debug.log "new_e" (print new_e)
            in
                (env1, (EGraphic ws s new_e, fl), st_)

        (e, DCtt (PVar _ s) d) ->
            let
                (env_, (e_, fl), st1) =
                    beval env e d ((s, (env, EError "IIIegal Constraint"))::st)
            in
            if e_ == EError "Fusion Failed" then
                (env, fuse delta exp, st)
            else
            case st1 of
                (_, (_, EError _)) :: st_ ->
                    (env, fuse delta exp, st_)

                (_, (_, sub)) :: st_ ->
                    let
                        fun = ELam ["",""] (PVar [""] s) e_
                    in
                    (env_, (EApp [] (pars " " fun) (pars "" sub), fl), st_)
                
                _ -> ([], EError "Error 21" |> empFunList, [])

        (e, DGroup s d) ->
            let
                (env_, (e_, fl), st1) =
                    beval env e d ((s, ([], EEmpList []))::st)
            in
            case st1 of
                (_, (_, ls)) :: st_ ->
                    let
                        group = 
                            EGraphic [" "] "g" (EList ["", ""] (EFloat [""] 0) (EList [""] ls (EEmpList [])))
                    in
                    (env_,  (ECons [""] (EVar [""] s) e_, fl ++ [(s, group)]), st_)
                
                _ -> ([], EError "Error 05" |> empFunList, [])

        (e, DCom d1 d2) ->
            let
                (env1, (e1, fl1), st1) = beval env e d1 st
            in
            if e1 == EError "Fusion Failed" then
                (env, fuse delta exp, st)
            else
            let
                (env2, (e2, fl2), st2) = beval env1 e1 d2 st
            in
            if e2 == EError "Fusion Failed" then
                (env, fuse delta exp, st)
            else
                (env2, (e2, fl1 ++ fl2), mergeST st1 st2)
        
        (_, DError info) -> ([], EError info |> empFunList, [])
        (_, _)           -> ([], EError "Cannot Handle This Delta" |> empFunList, [])
                            -- beval env exp (deval [] d) st



empFunList : Exp -> (Exp, List (String, Exp))
empFunList exp =
    (exp, [])