/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import Init.Lean.Environment
import Init.Lean.AuxRecursor
import Init.Lean.ProjFns

namespace Lean

/- ===========================
   Helper functions for reducing recursors
   =========================== -/

private def getFirstCtor (env : Environment) (d : Name) : Option Name :=
match env.find d with
| some (ConstantInfo.inductInfo { ctors := ctor::_, ..}) => some ctor
| _ => none

private def mkNullaryCtor (env : Environment) (type : Expr) (nparams : Nat) : Option Expr :=
match type.getAppFn with
| Expr.const d lvls =>
  match getFirstCtor env d with
  | some ctor => mkApp (Expr.const ctor lvls) (type.getAppArgs.shrink nparams)
  | none      => none
| _ => none

private def toCtorIfLit : Expr → Expr
| Expr.lit (Literal.natVal v) =>
  if v == 0 then Expr.const `Nat.zero []
  else Expr.app (Expr.const `Nat.succ []) (Expr.lit (Literal.natVal (v-1)))
| e => e

private def getRecRuleFor (rec : RecursorVal) (major : Expr) : Option RecursorRule :=
match major.getAppFn with
| Expr.const fn _ => rec.rules.find $ fun r => r.ctor == fn
| _ => none

@[specialize] private def toCtorWhenK {m : Type → Type} [Monad m]
    (whnf      : Expr → m Expr)
    (inferType : Expr → m Expr)
    (isDefEq   : Expr → Expr → m Bool)
    (env : Environment) (rec : RecursorVal) (major : Expr) : m (Option Expr) :=
do majorType ← inferType major;
   majorType ← whnf majorType;
   let majorTypeI := majorType.getAppFn;
   if !majorTypeI.isConstOf rec.getInduct then
     pure none
   else if majorType.hasExprMVar && majorType.getAppArgs.anyFrom Expr.hasExprMVar rec.nparams then
     pure none
   else
     match mkNullaryCtor env majorType rec.nparams with
     | none => pure none
     | some newCtorApp => do
       newType ← inferType newCtorApp;
       defeq ← isDefEq majorType newType;
       pure $ if defeq then newCtorApp else none

/-- Auxiliary function for reducing recursor applications. -/
@[specialize] def reduceRecAux {α} {m : Type → Type} [Monad m]
    (whnf      : Expr → m Expr)
    (inferType : Expr → m Expr)
    (isDefEq   : Expr → Expr → m Bool)
    (env : Environment) (rec : RecursorVal) (recLvls : List Level) (recArgs : Array Expr)
    (failK : Unit → m α) (successK : Expr → m α) : m α :=
let majorIdx := rec.getMajorIdx;
if h : majorIdx < recArgs.size then do
  let major := recArgs.get ⟨majorIdx, h⟩;
  major ← whnf major;
  major ←
    if !rec.k then
      pure major
    else do {
      newMajor ← toCtorWhenK whnf inferType isDefEq env rec major;
      pure (newMajor.getD major)
    };
  let major := toCtorIfLit major;
  match getRecRuleFor rec major with
  | some rule =>
    let majorArgs := major.getAppArgs;
    if recLvls.length != rec.lparams.length then
      failK ()
    else
      let rhs := rule.rhs.instantiateLevelParams rec.lparams recLvls;
      -- Apply parameters, motives and minor premises from recursor application.
      let rhs := mkAppRange rhs 0 (rec.nparams+rec.nmotives+rec.nminors) recArgs;
      /- The number of parameters in the constructor is not necessarily
         equal to the number of parameters in the recursor when we have
         nested inductive types. -/
      let nparams := majorArgs.size - rule.nfields;
      let rhs := mkAppRange rhs nparams majorArgs.size majorArgs;
      let rhs := mkAppRange rhs (majorIdx + 1) recArgs.size recArgs;
      successK rhs
  | none => failK ()
else
  failK ()

@[inline] private def matchRecApp {α} {m : Type → Type} [Monad m] (env : Environment)
   (e : Expr) (failK : Unit → m α) (k : RecursorVal → List Level → Array Expr → m α) : m α :=
matchConst env e.getAppFn failK $ fun cinfo recLvls =>
  match cinfo with
  | ConstantInfo.recInfo rec => k rec recLvls e.getAppArgs
  | _ => failK ()

/-- Reduce recursor applications. -/
@[specialize] def reduceRec {α} {m : Type → Type} [Monad m]
    (whnf      : Expr → m Expr)
    (inferType : Expr → m Expr)
    (isDefEq   : Expr → Expr → m Bool)
    (env : Environment) (e : Expr)
    (failK : Unit → m α) (successK : Expr → m α) : m α :=
matchRecApp env e failK $ fun rec recLvls recArgs => reduceRecAux whnf inferType isDefEq env rec recLvls recArgs failK successK

@[specialize] def isRecStuck {m : Type → Type} [Monad m]
    (whnf    : Expr → m Expr)
    (isStuck : Expr → m (Option Expr))
    (env : Environment) (e : Expr) : m (Option Expr) :=
matchRecApp env e (fun _ => pure none) $ fun rec recLvls recArgs =>
  if rec.k then
    -- TODO: improve this case
    pure none
  else do
    let majorIdx := rec.getMajorIdx;
    if h : majorIdx < recArgs.size then do
      let major := recArgs.get ⟨majorIdx, h⟩;
      major ← whnf major;
      isStuck major
    else
      pure none

/- ===========================
   Helper functions for reducing Quot.lift and Quot.ind
   =========================== -/

/-- Auxiliary function for reducing `Quot.lift` and `Quot.ind` applications. -/
@[specialize] def reduceQuotRecAux {α} {m : Type → Type} [Monad m]
    (whnf : Expr → m Expr)
    (env  : Environment)
    (rec  : QuotVal) (recLvls : List Level) (recArgs : Array Expr)
    (failK : Unit → m α) (successK : Expr → m α) : m α :=
let process (majorPos argPos : Nat) : m α :=
  if h : majorPos < recArgs.size then do
    let major := recArgs.get ⟨majorPos, h⟩;
    major ← whnf major;
    match major with
    | Expr.app (Expr.app (Expr.app (Expr.const majorFn _) _) _) majorArg =>
      match env.find majorFn with
      | some (ConstantInfo.quotInfo { kind := QuotKind.ctor, .. }) =>
        let f := recArgs.get! argPos;
        let r := Expr.app f majorArg;
        let recArity := majorPos + 1;
        successK $ mkAppRange r recArity recArgs.size recArgs
      | _ => failK ()
    | _ => failK ()
  else
    failK ();
match rec.kind with
| QuotKind.lift => process 5 3
| QuotKind.ind  => process 4 3
| _             => failK ()

@[inline] private def matchQuotRecApp {α} {m : Type → Type} [Monad m] (env : Environment)
   (e : Expr) (failK : Unit → m α) (k : QuotVal → List Level → Array Expr → m α) : m α :=
matchConst env e.getAppFn failK $ fun cinfo recLvls =>
  match cinfo with
  | ConstantInfo.quotInfo rec => k rec recLvls e.getAppArgs
  | _ => failK ()

@[specialize] def reduceQuotRec {α} {m : Type → Type} [Monad m]
    (whnf : Expr → m Expr)
    (env : Environment) (e : Expr)
    (failK : Unit → m α) (successK : Expr → m α) : m α :=
matchQuotRecApp env e failK $ fun rec recLvls recArg => reduceQuotRecAux whnf env rec recLvls recArg failK successK

@[specialize] def isQuotRecStuck {m : Type → Type} [Monad m]
    (whnf : Expr → m Expr)
    (isStuck : Expr → m (Option Expr))
    (env : Environment) (e : Expr) : m (Option Expr) :=
matchQuotRecApp env e (fun _ => pure none) $ fun rec recLvls recArgs =>
  let process (majorPos : Nat) : m (Option Expr) :=
    if h : majorPos < recArgs.size then do
      let major := recArgs.get ⟨majorPos, h⟩;
      major ← whnf major;
      isStuck major
    else
      pure none;
  match rec.kind with
  | QuotKind.lift => process 5
  | QuotKind.ind  => process 4
  | _             => pure none

/- ===========================
   Helper functions for reducing user-facing projection functions
   =========================== -/

@[specialize] def reduceProjectionFnAux {α} {m : Type → Type} [Monad m]
    (whnf : Expr → m Expr)
    (env : Environment) (projInfo : ProjectionFunctionInfo) (projArgs : Array Expr)
    (failK : Unit → m α) (successK : Expr → m α) : m α :=
let majorIdx := projInfo.nparams;
if h : majorIdx < projArgs.size then do
  let major := projArgs.get ⟨majorIdx, h⟩;
  major ← whnf major;
  matchConst env major.getAppFn failK $ fun majorInfo majorLvls =>
    let i := projInfo.nparams + projInfo.i;
    if i < major.getAppNumArgs then
      successK $ mkAppRange (major.getArg! i) (majorIdx + 1) projArgs.size projArgs
    else
      failK ()
else
  failK ()

@[specialize] def reduceProjectionFn {α} {m : Type → Type} [Monad m]
    (whnf : Expr → m Expr)
    (env : Environment) (e : Expr)
    (failK : Unit → m α) (successK : Expr → m α) : m α :=
matchConst env e.getAppFn failK $ fun cinfo _ =>
  match env.getProjectionFnInfo cinfo.name with
  | some projInfo => reduceProjectionFnAux whnf env projInfo e.getAppArgs failK successK
  | none => failK ()

/- ===========================
   Weak Head Normal Form auxiliary combinators
   =========================== -/

/-- Auxiliary combinator for handling easy WHNF cases. It takes a function for handling the "hard" cases as an argument -/
@[specialize] private partial def whnfEasyCases {m : Type → Type} [Monad m]
    (getLocalDecl      : Name → m LocalDecl)
    (getMVarAssignment : Name → m (Option Expr))
    : Expr → (Expr → m Expr) → m Expr
| e@(Expr.forallE _ _ _ _), _ => pure e
| e@(Expr.lam _ _ _ _),     _ => pure e
| e@(Expr.sort _),          _ => pure e
| e@(Expr.lit _),           _ => pure e
| e@(Expr.bvar _),          _ => unreachable!
| Expr.mdata _ e,           k => whnfEasyCases e k
| e@(Expr.letE _ _ _ _),    k => k e
| e@(Expr.fvar fvarId),     k => do
  decl ← getLocalDecl fvarId;
  match decl.valueOpt with
  | none   => pure e
  | some v => whnfEasyCases v k
| e@(Expr.mvar mvarId),     k => do
  optV ← getMVarAssignment mvarId;
  match optV with
  | some v => whnfEasyCases v k
  | none   => pure e
| e@(Expr.const _ _),       k => k e
| e@(Expr.app _ _),         k => k e
| e@(Expr.proj _ _ _),      k => k e

/-- Return true iff term is of the form `idRhs ...` -/
private def isIdRhsApp (e : Expr) : Bool :=
e.isAppOf `idRhs

/-- (@idRhs T f a_1 ... a_n) ==> (f a_1 ... a_n) -/
private def extractIdRhs (e : Expr) : Expr :=
if !isIdRhsApp e then e
else
  let args := e.getAppArgs;
  if args.size < 2 then e
  else mkAppRange (args.get! 1) 2 args.size args

@[specialize] private def deltaBetaDefinition {α} (c : ConstantInfo) (lvls : List Level) (revArgs : Array Expr)
    (failK : Unit → α) (successK : Expr → α) : α :=
if c.lparams.length != lvls.length then failK ()
else
  let val := c.instantiateValueLevelParams lvls;
  let val := val.betaRev revArgs;
  successK (extractIdRhs val)

/--
  Apply beta-reduction, zeta-reduction (i.e., unfold let local-decls), iota-reduction,
  expand let-expressions, expand assigned meta-variables.

  This method does *not* apply delta-reduction at the head.
  Reason: we want to perform these reductions lazily at isDefEq.

  Remark: this method delta-reduce (transparent) aux-recursors (e.g., casesOn, recOon) IF
  `reduceAuxRec? == true`, and user-facing projection functions if `reduceProjFn? == true` -/
@[specialize] private partial def whnfCore {m : Type → Type} [Monad m]
    (whnf              : Expr → m Expr)
    (inferType         : Expr → m Expr)
    (isDefEq           : Expr → Expr → m Bool)
    (getLocalDecl      : Name → m LocalDecl)
    (getMVarAssignment : Name → m (Option Expr))
    (env : Environment)
    (reduceAuxRec? : Bool) (reduceProjFn? : Bool) : Expr → m Expr
| e => whnfEasyCases getLocalDecl getMVarAssignment e $ fun e =>
  match e with
  | e@(Expr.const _ _)    => pure e
  | e@(Expr.letE _ _ v b) => whnfCore $ b.instantiate1 v
  | e@(Expr.app f _)      => do
    let f := f.getAppFn;
    f' ← whnfCore f;
    if f'.isLambda then
      let revArgs := e.getAppRevArgs;
      whnfCore $ f.betaRev revArgs
    else do
      let done : Unit → m Expr := fun _ =>
        if f == f' then pure e else pure $ e.updateFn f';
      matchConst env f' done $ fun cinfo lvls =>
        match cinfo with
        | ConstantInfo.recInfo rec    => reduceRecAux whnf inferType isDefEq env rec lvls e.getAppArgs done whnfCore
        | ConstantInfo.quotInfo rec   => reduceQuotRecAux whnf env rec lvls e.getAppArgs done whnfCore
        | c@(ConstantInfo.defnInfo _) =>
          if reduceAuxRec? && isAuxRecursor env c.name then
            deltaBetaDefinition c lvls e.getAppArgs done whnfCore
          else if reduceProjFn? then
            match env.getProjectionFnInfo cinfo.name with
            | some projInfo => reduceProjectionFnAux whnf env projInfo e.getAppArgs done whnfCore
            | none          => done ()
          else
            done ()
        | _ => done ()
  | e@(Expr.proj _ i c) => do
    c   ← whnf c;
    matchConst env c.getAppFn (fun _ => pure e) $ fun cinfo lvls =>
      match cinfo with
      | ConstantInfo.ctorInfo ctorVal => pure $ c.getArgD (ctorVal.nparams + i) e
      | _ => pure e
  | _ => unreachable!

end Lean
