/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura, Jannis Limperg
-/
namespace Std
universe u
namespace BinomialHeapImp

structure HeapNodeAux (α : Type u) (h : Type u) where
  val : α
  rank : Nat
  children : List h

inductive Heap (α : Type u) : Type u where
  | heap (ns : List (HeapNodeAux α (Heap α))) : Heap α
  deriving Inhabited

open Heap

abbrev HeapNode α := HeapNodeAux α (Heap α)

variable {α : Type u}

def hRank : List (HeapNode α) → Nat
  | []   => 0
  | h::_ => h.rank

def isEmpty : Heap α → Bool
  | heap [] => true
  | _       => false

def empty : Heap α :=
  heap []

def singleton (a : α) : Heap α :=
  heap [{ val := a, rank := 1, children := [] }]

@[specialize] def combine (lt : α → α → Bool) (n₁ n₂ : HeapNode α) : HeapNode α :=
  if lt n₂.val n₁.val then
     { n₂ with rank := n₂.rank + 1, children := n₂.children ++ [heap [n₁]] }
  else
     { n₁ with rank := n₁.rank + 1, children := n₁.children ++ [heap [n₂]] }

@[specialize] partial def mergeNodes (lt : α → α → Bool) : List (HeapNode α) → List (HeapNode α) → List (HeapNode α)
  | [], h  => h
  | h,  [] => h
  | f@(h₁ :: t₁), s@(h₂ :: t₂) =>
    if h₁.rank < h₂.rank then h₁ :: mergeNodes lt t₁ s
    else if h₂.rank < h₁.rank then h₂ :: mergeNodes lt t₂ f
    else
      let merged := combine lt h₁ h₂
      let r      := merged.rank
      if r != hRank t₁ then
        if r != hRank t₂ then merged :: mergeNodes lt t₁ t₂ else mergeNodes lt (merged :: t₁) t₂
      else
        if r != hRank t₂ then mergeNodes lt t₁ (merged :: t₂) else merged :: mergeNodes lt t₁ t₂

@[specialize] def merge (lt : α → α → Bool) : Heap α → Heap α → Heap α
  | heap h₁, heap h₂ => heap (mergeNodes lt h₁ h₂)

@[specialize] def head? (lt : α → α → Bool) : Heap α → Option α
  | heap []      => none
  | heap (h::hs) => some $
    hs.foldl (init := h.val) fun r n => if lt r n.val then r else n.val

@[inline] def head [Inhabited α] (lt : α → α → Bool) (h : Heap α) : α :=
  head? lt h |>.getD arbitrary

@[specialize] def findMin (lt : α → α → Bool) : List (HeapNode α) → Nat → HeapNode α × Nat → HeapNode α × Nat
  | [],    _,   r          => r
  | h::hs, idx, (h', idx') => if lt h'.val h.val then findMin lt hs (idx+1) (h', idx') else findMin lt hs (idx+1) (h, idx)
    -- It is important that we check `lt h'.val h.val` here, not the other way
    -- around. This ensures that head? and findMin find the same element even
    -- when we have `lt h'.val h.val` and `lt h.val h'.val` (i.e. lt is not
    -- irreflexive).

def tail (lt : α → α → Bool) : Heap α → Heap α
  | heap []  => empty
  | heap [h] =>
    match h.children with
    | []      => empty
    | (h::hs) => hs.foldl (merge lt) h
  | heap hhs@(h::hs) =>
    let (min, minIdx) := findMin lt hs 1 (h, 0)
    let rest          := hhs.eraseIdx minIdx
    min.children.foldl (merge lt) (heap rest)

partial def toList (lt : α → α → Bool) (h : Heap α) : List α :=
  match head? lt h with
  | none   => []
  | some a => a :: toList lt (tail lt h)

partial def toArray (lt : α → α → Bool) (h : Heap α) : Array α :=
  go #[] h
  where
    go (acc : Array α) (h : Heap α) : Array α :=
      match head? lt h with
      | none => acc
      | some a => go (acc.push a) (tail lt h)

partial def toListUnordered : Heap α → List α
  | heap ns => ns.bind fun n => n.val :: n.children.bind toListUnordered

partial def toArrayUnordered (h : Heap α) : Array α :=
  go #[] h
  where
    go (acc : Array α) : Heap α → Array α
      | heap ns => do
        let mut acc := acc
        for n in ns do
          acc := acc.push n.val
          for h in n.children do
            acc := go acc h
        return acc

inductive WellFormed (lt : α → α → Bool) : Heap α → Prop where
  | emptyWff                  : WellFormed lt empty
  | singletonWff (a : α)      : WellFormed lt (singleton a)
  | mergeWff (h₁ h₂ : Heap α) : WellFormed lt h₁ → WellFormed lt h₂ → WellFormed lt (merge lt h₁ h₂)
  | tailWff (h : Heap α)      : WellFormed lt h → WellFormed lt (tail lt h)

end BinomialHeapImp

open BinomialHeapImp

def BinomialHeap (α : Type u) (lt : α → α → Bool) := { h : Heap α // WellFormed lt h }

@[inline] def mkBinomialHeap (α : Type u) (lt : α → α → Bool) : BinomialHeap α lt :=
  ⟨empty, WellFormed.emptyWff⟩

namespace BinomialHeap
variable {α : Type u} {lt : α → α → Bool}

@[inline] def empty : BinomialHeap α lt :=
  mkBinomialHeap α lt

@[inline] def isEmpty : BinomialHeap α lt → Bool
  | ⟨b, _⟩ => BinomialHeapImp.isEmpty b

/- O(1) -/
@[inline] def singleton (a : α) : BinomialHeap α lt :=
  ⟨BinomialHeapImp.singleton a, WellFormed.singletonWff a⟩

/- O(log n) -/
@[inline] def merge : BinomialHeap α lt → BinomialHeap α lt → BinomialHeap α lt
  | ⟨b₁, h₁⟩, ⟨b₂, h₂⟩ => ⟨BinomialHeapImp.merge lt b₁ b₂, WellFormed.mergeWff b₁ b₂ h₁ h₂⟩

/- O(log n) -/
@[inline] def head [Inhabited α] : BinomialHeap α lt → α
  | ⟨b, _⟩ => BinomialHeapImp.head lt b

/- O(log n) -/
@[inline] def head? : BinomialHeap α lt → Option α
  | ⟨b, _⟩ => BinomialHeapImp.head? lt b

/- O(log n) -/
@[inline] def tail : BinomialHeap α lt → BinomialHeap α lt
  | ⟨b, h⟩ => ⟨BinomialHeapImp.tail lt b, WellFormed.tailWff b h⟩

/- O(log n) -/
@[inline] def insert (a : α) (h : BinomialHeap α lt) : BinomialHeap α lt :=
  merge (singleton a) h

/- O(n log n) -/
@[inline] def toList : BinomialHeap α lt → List α
  | ⟨b, _⟩ => BinomialHeapImp.toList lt b

/- O(n log n) -/
@[inline] def toArray : BinomialHeap α lt → Array α
  | ⟨b, _⟩ => BinomialHeapImp.toArray lt b

/- O(n) -/
@[inline] def toListUnordered : BinomialHeap α lt → List α
  | ⟨b, _⟩ => BinomialHeapImp.toListUnordered b

/- O(n) -/
@[inline] def toArrayUnordered : BinomialHeap α lt → Array α
  | ⟨b, _⟩ => BinomialHeapImp.toArrayUnordered b

end BinomialHeap
end Std
