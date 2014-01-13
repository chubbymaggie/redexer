(*
 * Copyright (c) 2010-2014,
 *  Jinseong Jeon <jsjeon@cs.umd.edu>
 *  Kris Micinski <micinski@cs.umd.edu>
 *  Jeff Foster   <jfoster@cs.umd.edu>
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. The names of the contributors may not be used to endorse or promote
 * products derived from this software without specific prior written
 * permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *)

(***********************************************************************)
(* Directed Exploration                                                *)
(***********************************************************************)

module St = Stats
module DA = DynArray

module U = Util

module J = Java
module I = Instr
module D = Dex

module V = Visitor

module Adr = Android
module App = Adr.App
module Ads = Adr.Ads

module Cg = Callgraph

module L = List

module Pf = Printf
module RE = Str

(***********************************************************************)
(* Basic Types/Elements                                                *)
(***********************************************************************)

module IdxPair =
struct
  type t = D.link * D.link
  let compare (cid1, mid1) (cid2, mid2) =
    let c = D.IdxKey.compare cid1 cid2 in
    if c <> 0 then c else D.IdxKey.compare mid1 mid2
end

module IPS = Set.Make(IdxPair)

module IS = Set.Make(D.IdxKey)

let id_folder acc id = IS.add id acc

type path = Cg.cc list

(***********************************************************************)
(* Step 1. find the methods in which the target calls appear           *)
(***********************************************************************)

let call_sites = ref IPS.empty

class target_finder (dx: D.dex) (apis: IPS.t) =
object
  inherit V.iterator dx

  val mutable cur_cid = D.no_idx
  method v_cdef (cdef: D.class_def_item) : unit =
    cur_cid <- cdef.D.c_class_id;
    let cname = J.of_java_ty (D.get_ty_str dx cur_cid) in
    skip_cls <- Adr.is_static_library cname || Ads.is_ads_pkg cname

  val mutable cur_mid = D.no_idx
  method v_emtd (emtd: D.encoded_method) : unit =
    cur_mid <- emtd.D.method_idx

  method v_ins (ins: D.link) : unit =
    if not (D.is_ins dx ins) then () else
      let op, opr = D.get_ins dx ins in
      match I.access_link op with
      | I.METHOD_IDS (* except for super call *)
        when not (L.mem op [I.OP_INVOKE_SUPER; I.OP_INVOKE_SUPER_RANGE]) ->
      (
        let mid = D.opr2idx (U.get_last opr) in
        let cid = D.get_cid_from_mid dx mid in
        if IPS.mem (cid, mid) apis then
          call_sites := IPS.add (cur_cid, cur_mid) !call_sites
      )
      | _ -> ()

end

let find_api_usage (dx: D.dex) (data: string) : IPS.t =
  let ch = open_in data in
  let lst = U.read_lines ch in
  close_in ch;
  let re = RE.regexp "\\(.+\\)->\\(.+\\)" in
  let each_line acc (str: string) =
    let _ = RE.search_forward re str 0 in
    let cname = RE.matched_group 1 str
    and mname = RE.matched_group 2 str in
    (cname, mname) :: acc
  in
  let s_apis = L.fold_left each_line [] lst
  in
  let apis = ref IPS.empty in
  let find_ids (cname, mname) =
    let cid = D.get_cid dx cname in
    if D.no_idx = cid then
      Log.w (Pf.sprintf "can't find class %s" cname)
    else try
      let mid, _ = D.get_the_mtd dx cid mname in
      apis := IPS.add (cid, mid) !apis
    with D.Wrong_dex _ ->
      Log.w (Pf.sprintf "can't find method %s->%s" cname mname)
  in
  L.iter find_ids s_apis;

  call_sites := IPS.empty;
  St.time "api" V.iter (new target_finder dx !apis);
  !call_sites

(***********************************************************************)
(* Step 2. build call graph, including component transition            *)
(***********************************************************************)

let depth = ref 6

let make_cg (dx: D.dex) (acts: string list)  : Cg.cg =
(*
  St.time "cg" Cg.make_cg dx
*)
  (* Activity(s) declared in the manifest, along with their superclasses *)
  let add_act acc act =
    let cid = D.get_cid dx (J.to_java_ty act) in
    if cid = D.no_idx then acc else
      L.fold_left id_folder acc (D.get_superclasses dx cid)
  in
  let act_cids = L.fold_left add_act IS.empty acts
  in
  (* *Listener that reacts to user interactions *)
  let is_listener cid =
    let ends_w_listener cid = U.ends_with (D.get_ty_str dx cid) "Listener;" in
    L.exists ends_w_listener (D.get_interfaces dx cid)
  in
  let add_listener acc cdef =
    let cid = cdef.D.c_class_id in
    if is_listener cid then id_folder acc cid else acc
  in
  let cids = DA.fold_left add_listener act_cids dx.D.d_class_defs in
  St.time "cg" (Cg.make_partial_cg dx !depth) (IS.elements cids)

(***********************************************************************)
(* Step 3. backtrack from the target methods to the target classes     *)
(***********************************************************************)

(**

  ma -> mb ---> m2 (* user interaction *)

  m1 -> m4; m2 -> m4; m3 -> m5;
       m4 -> m6;      m5 -> m6;

  callers... m6 = [ [m6; m4; m1]; [m6; m4; m2]; [m6; m5; m3] ]

    implicit call chain: mb ---> m2

  callers... mb = [ [mb; ma] ]

    finish if ma is inside one of target classes

  backtrack... = [ [ [mb; ma]; [m6; m4; m2] ]; ... ]

*)

let path_to_str (dx: D.dex) (p: path) : string =
  let mtd_to_str mid =
    let cid = D.get_cid_from_mid dx mid in
    let cname = D.get_ty_str dx cid
    and mname = D.get_mtd_name dx mid in
    Pf.sprintf "%s.%s" cname mname
  in
  let per_explicit mids =
    let join acc mid =
      let next = mtd_to_str mid in
      if acc = "" then next else next^"\n----> "^acc
    in
    L.fold_left join "" mids
  in
  let per_ui acc mids =
    let next = per_explicit mids in
    if acc = "" then "      "^next else acc^"\n-UI-> "^next
  in
  L.fold_left per_ui "" p

exception PATH_W_CYCLE

let has_cycle (visited: IS.t) (p: path) : bool =
  let v_mid acc mid =
    if IS.mem mid acc then raise PATH_W_CYCLE else id_folder acc mid
  in
  try ignore (L.fold_left v_mid visited (L.flatten p)); false
  with PATH_W_CYCLE -> true

let induce_cycle (cc: Cg.cc) (p: path) : bool =
  let visited = L.fold_left id_folder IS.empty cc in
  has_cycle visited p

let backtrack (dx: D.dex) cg (call_sites: IPS.t) (tgt_cids: IS.t) : path list =
  let is_act =
    let ends_w_act cid = U.ends_with (D.get_ty_str dx cid) "Activity;" in
    D.in_hierarchy dx ends_w_act
  in
  let rec gen_path ps : path list =
    let per_path p =
      if [] = p then [] else
      let last_mid = U.get_last (L.hd p) in
      let cid = D.get_cid_from_mid dx last_mid in
      (* reach one of the target classes *)
      if IS.mem cid tgt_cids then [p]
      (* go to Activity.onCreate(), assuming user interaction *)
      else if is_act cid then
      (
        let mids = Adr.find_lifecycle_act dx cid in
        if [] = mids then [] else
          let on_mid = L.hd mids in
          let ccs = Cg.callers dx 9 cg on_mid in
          (* if |callers| == 1 then no more interesting call chains *)
          if 1 = L.length ccs && 1 = L.length (L.hd ccs) then [p] else
            let add_unless_cycle cc =
              if induce_cycle cc p then [] else cc :: p
            in
            gen_path (L.rev_map add_unless_cycle ccs)
      )
      else (* unexplored boundary *)
      (
        let cname = D.get_ty_str dx cid
        and mname = D.get_mtd_name dx last_mid in
        Log.d (Pf.sprintf "can't explore further: %s->%s" cname mname);
        []
      )
    in
    L.flatten (L.rev_map per_path ps)
  in
  let to_path (_, mid) = L.rev_map (fun p -> [p]) (Cg.callers dx 9 cg mid) in
  let ps = L.flatten (L.rev_map to_path (IPS.elements call_sites)) in
  St.time "backtrack" gen_path ps 

(***********************************************************************)
(* Step 4. instrument necessary user interactions                      *)
(***********************************************************************)



(***********************************************************************)
(* Putting all together                                                *)
(***********************************************************************)

let compare_path (p1: path) (p2: path) : int =
  let c = compare (L.length p1) (L.length p2) in
  if 0 <> c then c else
    let len_sum acc cc = acc + (L.length cc) in
    let l1 = L.fold_left len_sum 0 p1
    and l2 = L.fold_left len_sum 0 p2 in
    compare l1 l2

(* directed_explore : D.dex -> string -> string list -> unit *)
let directed_explore (dx: D.dex) (data: string) (acts: string list) : unit =
  let call_sites = find_api_usage dx data
  and cg = make_cg dx acts in
  (* assume the first element is the main Activity *)
  let main_act = L.hd acts in
  let main_cid = IS.singleton (D.get_cid dx main_act) in
  let ps = backtrack dx cg call_sites main_cid
  and per_path p =
    Log.i "\n====== path ======";
    Log.i (path_to_str dx p)
  in
  L.iter per_path (L.stable_sort compare_path ps)
