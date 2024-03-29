module Language.Fusion exposing (..)

import Utils exposing (setLast)
import Printer.Exp exposing (print)
import Language.Syntax exposing (..)
import Language.Utils exposing (varsInPattern)
import Language.UtilsFD exposing (param2Exp, eqDelta)

fuse : Delta -> Exp -> (Exp, List (String, Exp))
fuse delta exp =
    if checkDeltaToFuse delta True |> not then
        (EError "Fusion Failed", [])
    else
        fuse_ delta exp


fuse_ : Delta -> Exp -> (Exp, List (String, Exp))
fuse_ delta exp =
    case delta of
        DId      -> (exp, [])
        DAbst p  -> (param2Exp p, [])
        DRewr p  -> (param2Exp p, [])

        DCtt p d ->
            case p of
                PVar _ var ->
                    case getCttParamPath d (AVar var) [] of
                        Just path -> 
                            let
                                getCttParam = ELam ["",""] (PVar [""] "obj") (genFunByPath path)
                                (body, fl)  = fuse_ d (EVar [""] "obj")
                                setCttFun   = ELam ["", ""] p (ELam ["",""] (PVar [""] "obj") (fuseFunInCtt fl body))
                                cttFun = ELam ["", ""] (PVar [""] "obj") 
                                        (EApp [] (EApp [] (EVar [" "] "setCttFun") 
                                        (EApp [] (EVar [" "] "getCttParam") (EVar [""] "obj") |> pars " ")) 
                                        (EVar [""] "obj"))
                            in
                                ( EApp [] (EVar [" "] "cttFun") (pars "" exp)
                                ,  [("getCttParam", getCttParam), ("setCttFun", setCttFun), ("cttFun", cttFun)])
                        
                        Nothing   -> (EError "Error 57", [])
                
                _          -> (EError "Error 58", [])
        
        DAdd p ->
            let
                spc = getLastSpaces exp
            in
                (EBPrim [""] Add (pars "" exp |> setLastSpaces "") (param2Exp p) |> pars spc, [])
        
        DMul p ->
            let
                spc = getLastSpaces exp
            in
                (EBPrim [""] Mul (pars "" exp) (param2Exp p) |> pars spc, [])

        DMap d ->
            if eqDelta d DId then
                (exp, [])
            else
                let
                    spc = getLastSpaces exp
                    (funBody, fl) = fuse_ d (EVar [""] "params")
                in
                    (EMap [" "] (ELam ["", ""] (PVar [""] "params") funBody |> pars " ") (exp |> pars spc), fl)


        DCopy n -> 
            let
                spc = getLastSpaces exp
            in
                (EApp [] (EApp [] 
                (EVar [" "] "cp")
                (EFloat [" "] (toFloat n))) 
                (exp |> pars spc)
                , [])

        DDelete n ->
            let
                spc = getLastSpaces exp
            in
                (EApp [] (EApp [] 
                (EVar [" "] "del") 
                (EFloat [" "] (toFloat n))) 
                (exp |> pars spc)
                , [])
        
        DModify n d ->
            let
                spc = getLastSpaces exp
            in
            if eqDelta d DId then 
                (exp, [])
            else
                let 
                    (funBody, fl) = fuse_ d (EVar [""] "x") 
                in
                    (EApp [] (EApp [] (EApp [] 
                    (EVar [" "] "mod")
                    (EFloat [" "] (toFloat n))) 
                    (ELam ["", ""] (PVar [""] "x") funBody |> pars " "))
                    (exp |> pars spc)
                    , fl)

        DInsert n p ->
            let
                spc =
                    exp |> getLastSpaces
            in
                (EApp [] (EApp [] (EApp [] 
                (EVar [" "] "ins") 
                (EFloat [" "] (toFloat n))) 
                (param2Exp p |> setLastSpaces " ")) 
                (exp |> pars spc)
                , [])
        
        DCons d1 d2 ->
            if eqDelta delta DId then
                (exp, [])
            else
                case exp of
                    ECons ws e1 e2 ->
                        let
                            (e1_, fl1) = fuse_ d1 e1
                            (e2_, fl2) = fuse_ d2 e2
                        in
                            (ECons ws e1_ e2_, fl1 ++ fl2)

                    EList ws e1 e2 ->
                        let
                            (e1_, fl1) = fuse_ d1 e1
                            (e2_, fl2) = fuse_ d2 e2
                        in
                            (EList ws e1_ e2_, fl1 ++ fl2)

                    _ ->
                        let
                            deltas = d1 :: expandDCons d2
                            varNum = List.length deltas
                            par = genNPCons (varNum - 1)
                            (body, fl) = genNFusedECons delta (varNum - 1)
                            fun = ELam ["", ""] par body
                        in
                            (EApp [] (EVar [" "] "consEdit") (pars "" exp) |> pars "", fl ++ [("consEdit", fun)])

        DTuple d1 d2 ->
            if eqDelta delta DId then
                (exp, [])
            else
                case exp of
                    ETuple ws e1 e2 ->
                        let
                            (e1_, fl1) = fuse_ d1 e1
                            (e2_, fl2) = fuse_ d2 e2
                        in
                            (ETuple ws e1_ e2_, fl1 ++ fl2)

                    _ ->
                        let
                            (e1_, fl1) = fuse_ d1 (EVar [""] "x")
                            (e2_, fl2) = fuse_ d2 (EVar [""] "y")
                            fun =
                                ELam ["", ""]
                                (PTuple ["","",""] (PVar [""] "x") (PVar [""] "y"))
                                (ETuple ["","",""] e1_ e2_)
                                |> pars " "
                        in
                            (EApp [] fun (pars "" exp), fl1 ++ fl2)
        
        DGen e (DFun p d) prm ->
            let
                -- expand = \x-> (1, x+1);

                -- recEdit = letrec rec = \next->\seed->\ls->
                --     case ls of
                --     [] -> []
                --     | x::xs ->
                --         case next seed of
                --         (a, next_seed) -> (\n->(x+n)) a :: rec next next_seed xs
                --     in rec;

                rec_fun = 
                    (ELam ["",""] (PVar [""] "next")
                    (ELam ["",""] (PVar [""] "seed") 
                    (ELam ["","\n    "] (PVar [""] "ls") 
                        (ECase [" ","\n    "] (EVar [" "] "ls") 
                        (BCom [" "] 
                            (BSin [" "] (PEmpList [""," "]) (EEmpList ["","\n    "])) 
                            (BSin ["\n        "] (PCons [""] (PVar [""] "x") (PVar [" "] "xs")) 
                                (ECase [" ","\n        "] (EApp [] (EVar [" "] "next") (EVar [" "] "seed")) 
                                    (BSin [" "] (PTuple [""," "," "] (PVar [""] "a") (PVar [""] "nextSeed")) 
                                    (ECons [" "] e1 e2)))))))))
                
                (editBody, fl) = fuse_ d (EVar [""] "graphic")
                editF = ELam ["", ""] (PVar [""] "graphic") (ELam ["",""] p editBody)
                e1 =  EApp [] (EApp [] (EVar [" "] "editF") (EVar [" "] "x"))  (EVar [" "] "a")
                e2 = -- rec next nextSeed xs
                    EVar ["\n    "] "xs" |>
                    EApp [] (
                        EVar [" "] "nextSeed" |>
                        EApp [] (
                            EVar [" "] "next" |>
                            EApp [] (EVar [" "] "rec")))

                recEdit = EApp ["LETREC"," "," "," "]
                    (ELam [] (PVar [" "] "rec") (EVar [""] "rec")) 
                    (EFix [] (ELam [] (PVar [" "] "rec") rec_fun))
                
                fusedExp = 
                    EApp [] (EApp [] (EApp [] 
                        (EVar [" "] "recEdit") 
                        (EVar [" "] "expand")) 
                        (param2Exp prm |> setLastSpaces " ")) 
                        (pars "" exp)

                funList = fl ++ [("editF", editF), ("expand", e), ("recEdit", recEdit)]
            in
                (fusedExp, funList)
        
        DCom d1 d2 ->
            let
                (exp1, fl1) = fuse_ d1 exp
                (exp2, fl2) = fuse_ d2 exp1
            in
                (exp2, fl1 ++ fl2)
        
        _ -> (EError "Fusion Failed", [])


getCttParamPath : Delta -> Param -> List (String, Int) -> Maybe (List (String, Int))
getCttParamPath delta param path =
    case delta of
        DAbst p      -> if p == param then Just path else Nothing
        DCons _ _    -> getCttParamDCons delta param path 0
        DCtt _ d     -> getCttParamPath d param path

        DTuple d1 d2 -> 
            case getCttParamPath d1 param (("Tuple", 1)::path) of
                Just p  -> Just p
                Nothing -> getCttParamPath d2 param (("Tuple", 2)::path)
        DCom d1 d2   ->
            case getCttParamPath d1 param path of
                Just p  -> Just p
                Nothing -> getCttParamPath d2 param path
        DModify n d  ->
            Maybe.map (\p -> p)
            <| getCttParamPath d param (("List", n)::path)
        DMap d       ->
            Maybe.map (\p -> p)
            <| getCttParamPath d param (("Graphic", 0)::path)

        _ -> Nothing


getCttParamDCons : Delta -> Param -> List (String, Int) -> Int 
                    -> Maybe (List (String, Int))
getCttParamDCons delta param path index =
    case delta of
        DCons d1 d2 ->
            case getCttParamPath d1 param (("List", index)::path) of
                Just p  -> Just p
                Nothing -> getCttParamDCons d2 param path (index + 1)
        
        _ -> Nothing


genFunByPath : List (String, Int) -> Exp
genFunByPath path =
    case path of
        []                    -> EVar [""] "obj"
        ("Graphic", 0)::path_ -> EUnwrap [" "] (genFunByPath path_ |> pars "")
        ("Tuple",   1)::path_ -> EApp [] (EVar [" "] "first")  (genFunByPath path_ |> pars "")
        ("Tuple",   2)::path_ -> EApp [] (EVar [" "] "second") (genFunByPath path_ |> pars "")
        ("List",    n)::path_ -> EApp [] (EApp [] (EVar [" "] "nth") (EFloat [" "] (toFloat n))) (genFunByPath path_ |> pars "")
        _                     -> EError "genFunByPath Failed"


pars : String -> Exp -> Exp
pars str e =
    case e of
        ELam _ _ _     -> EParens ["", str] (setLastSpaces "" e)
        EApp _ _ _     -> EParens ["", str] (setLastSpaces "" e)
        ECase _ _ _    -> EParens ["", str] (setLastSpaces "" e)
        EUPrim _ _ _   -> EParens ["", str] (setLastSpaces "" e)
        EBPrim _ _ _ _ -> EParens ["", str] (setLastSpaces "" e)
        ECons _ _ _    -> EParens ["", str] (setLastSpaces "" e)
        EGraphic _ _ _ -> EParens ["", str] (setLastSpaces "" e)
        EMap _ _ _     -> EParens ["", str] (setLastSpaces "" e)
        EUnwrap _ _    -> EParens ["", str] (setLastSpaces "" e)
        _              -> e


fuseVar : Delta -> String -> Exp -> (Exp, List (String, Exp))
fuseVar delta var exp =
    case exp of
        EVar _ s -> 
            if s == var then
                fuse delta exp
            else
                (exp, [])

        ELam _ p e ->
            if not (List.member var (varsInPattern p)) then
                let (e_, fl) = fuseVar delta var e in
                    (ELam [] p e_, fl)
            else
                (exp, [])
        
        EApp ws e1 e2  -> 
            let 
                (e1_, fl1) = fuseVar delta var e1
                (e2_, fl2) = fuseVar delta var e2
            in
                (EApp ws e1_ e2_, fl1 ++ fl2)
        
        ECase ws e bs  ->
            let
                (e_,  fl1) = fuseVar delta var e
                (bs_, fl2) = fuseVarBranch delta var bs
            in
                (ECase ws e_ bs_, fl1 ++ fl2)
        
        EBPrim ws bop e1 e2 -> 
            let 
                (e1_, fl1) = fuseVar delta var e1
                (e2_, fl2) = fuseVar delta var e2
            in
                (EBPrim ws bop e1_ e2_, fl1 ++ fl2)
        
        ECons ws e1 e2      -> 
            let
                (e1_, fl1) = fuseVar delta var e1
                (e2_, fl2) = fuseVar delta var e2
            in
                (ECons ws e1_ e2_, fl1 ++ fl2)

        EList ws e1 e2      -> 
            let
                (e1_, fl1) = fuseVar delta var e1
                (e2_, fl2) = fuseVar delta var e2
            in
                (EList ws e1_ e2_, fl1 ++ fl2)
        
        ETuple ws e1 e2     -> 
            let
                (e1_, fl1) = fuseVar delta var e1
                (e2_, fl2) = fuseVar delta var e2
            in
                (ETuple ws e1_ e2_, fl1 ++ fl2)
        
        EUPrim ws uop e -> 
            let
                (e_, fl) = fuseVar delta var e
            in
                (EUPrim ws uop e_, fl)

        EParens ws  e   -> 
            let
                (e_, fl) = fuseVar delta var e
            in
                (EParens ws e_, fl)
        
        EFix ws     e   -> 
            let
                (e_, fl) = fuseVar delta var e
            in
                (EFix ws e_, fl)

        EGraphic ws s e -> 
            let
                (e_, fl) = fuseVar delta var e
            in
                (EGraphic ws s e_, fl)

        EMap ws f e ->
            let
                (f_, fl1) = fuseVar delta var f
                (e_, fl2) = fuseVar delta var e
            in
                (EMap ws f_ e_, fl1 ++ fl2)

        EUnwrap ws e ->
            let
                (e_, fl) = fuseVar delta var e
            in
                (EUnwrap ws e_, fl)

        _ -> (exp, [])


fuseVarBranch : Delta -> String -> Branch -> (Branch, List (String, Exp))
fuseVarBranch delta var bs =
    case bs of
        BSin ws p e   -> 
            let
                (e_, fl) = fuseVar delta var e
            in
                (BSin ws p e_, fl)

        BCom ws b1 b2 -> 
            let
                (b1_, fl1) = fuseVarBranch delta var b1
                (b2_, fl2) = fuseVarBranch delta var b2
            in
                (BCom ws b1_ b2_, fl1 ++ fl2)


fuseEnv : List (String, Delta) -> Exp -> (Exp, List (String, Exp))
fuseEnv deltas exp =
    case deltas of
        []                   -> (exp, [])
        (var, delta) :: rest ->
            if checkDeltaToFuse delta True |> not then
                (EError "Fusion Failed", [])
            else
            let
                (exp1, fl1) = fuseEnv rest exp
                (exp2, fl2) = fuseVar delta var exp1
            in
                (exp2, fl1 ++ fl2)


getLastSpaces : Exp -> String
getLastSpaces exp =
    let
        isSpace c =
            if c == ' ' || c == '\n' || c == '\r' then
                True
            else
                False

        helper chars acc =
            case chars of
                [] ->
                    acc

                x :: xs ->
                    if isSpace x then
                        helper xs (String.cons x acc)
                    else
                        acc
    in
        helper (String.toList (exp |> print |> String.reverse)) ""


setLastSpaces : String -> Exp -> Exp
setLastSpaces str exp =
    case exp of
        ETrue    ws           -> ETrue    (setLast str ws)
        EFalse   ws           -> EFalse   (setLast str ws)
        ENil     ws           -> ENil     (setLast str ws)
        EEmpList ws           -> EEmpList (setLast str ws)
        EFloat   ws f         -> EFloat  (setLast str ws) f
        EChar    ws c         -> EChar   (setLast str ws) c
        EString  ws s         -> EString (setLast str ws) s
        EVar     ws s         -> EVar    (setLast str ws) s
        ELam     ws p e       -> ELam   ws p      (setLastSpaces str e)

        EApp ("LET"::ws)    e1 e2 -> EApp ("LET"   ::ws) (setLastSpaces str e1) e2
        EApp ("LETREC"::ws) e1 e2 -> EApp ("LETREC"::ws) (setLastSpaces str e1) e2

        EApp     ws e1 e2     -> EApp   ws e1     (setLastSpaces str e2)
        ECase    ws e bs      -> ECase  ws e      (setLastSpacesBranch str bs)
        EUPrim   ws uop e     -> EUPrim ws uop    (setLastSpaces str e)
        EBPrim   ws bop e1 e2 -> EBPrim ws bop e1 (setLastSpaces str e2)
        ECons    ws e1 e2     -> ECons  ws e1     (setLastSpaces str e2)
        EList    ws e1 e2     -> EList   (setLast str ws) e1 e2
        ETuple   ws e1 e2     -> ETuple  (setLast str ws) e1 e2
        EParens  ws e         -> EParens (setLast str ws) e
        EGraphic ws s e       -> EGraphic ws s  (setLastSpaces str  e)
        EMap     ws e1 e2     -> EMap     ws e1 (setLastSpaces str e2)
        _                     -> exp


setLastSpacesBranch : String -> Branch -> Branch
setLastSpacesBranch str bs =
    case bs of
        BSin ws p e   -> BSin ws p (setLastSpaces str e)
        BCom ws b1 b2 -> BCom ws b1 (setLastSpacesBranch str b2)


expandDCons : Delta -> List Delta
expandDCons d =
    case d of
        DCons d1 d2 -> d1 :: expandDCons d2
        _           -> [d]


genNPCons : Int -> Pattern
genNPCons n =
    case n of
        0 -> PVar [""] "x0"
        _ -> PCons [""] (PVar [""] ("x" ++ Debug.toString n)) (genNPCons (n - 1))


genNFusedECons : Delta -> Int -> (Exp, List (String, Exp))
genNFusedECons delta n =
    case delta of
        DCons d1 d2 -> 
            let
                (e1, fl1) = fuse_ d1 (EVar [""] ("x" ++ Debug.toString n))
                (e2, fl2) = genNFusedECons d2 (n - 1)
            in
                (ECons [""] e1 e2, fl1 ++ fl2)
        
        _           -> fuse_ delta (EVar [""] "x0")


fuseFunList : List (String, Exp) -> Exp -> Exp
fuseFunList funs fuseObj =
    case funs of
        [] -> fuseObj
        (var, exp) :: rest ->
            EApp ["EQ", " ", " ", "\n"] (ELam [] (PVar [""] var) (fuseFunList rest fuseObj)) exp


checkDeltaToFuse : Delta -> Bool -> Bool
checkDeltaToFuse delta flag =
    case delta of
        DCons  d1 d2 -> checkDeltaToFuse d1 flag && checkDeltaToFuse d2 flag
        DTuple d1 d2 -> checkDeltaToFuse d1 flag && checkDeltaToFuse d2 flag
        DCom d1 d2 -> checkDeltaToFuse d1 flag && checkDeltaToFuse d2 flag

        DModify _ d  -> checkDeltaToFuse d flag
        DMap      d  -> checkDeltaToFuse d flag
        DGen _ d _   -> checkDeltaToFuse d flag
        DGroup _  d  -> checkDeltaToFuse d flag
        DApp d _     -> checkDeltaToFuse d flag
        DFun _ d     -> checkDeltaToFuse d flag
        DCtt _ _     -> True
        
        DAbst  _ -> False
        DError _ -> False
        DRewr  _ -> True
        _        -> True


fuseFunInCtt : List (String, Exp) -> Exp -> Exp
fuseFunInCtt fl exp =
    case fl of
        (f, e)::fl_ -> EApp ["LET", " ", " ", "\n"] (ELam [] (PVar [""] f) (fuseFunInCtt fl_ exp)) (e |> setLastSpaces " ")
        []          -> exp