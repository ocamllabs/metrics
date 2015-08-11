
open Lwt
open CalendarLib

let day_1 = Date.Period.day (-1)
let day_2 = Date.Period.day (-2)
let day_3 = Date.Period.day (-3)
let day_4 = Date.Period.day (-4)
let day_5 = Date.Period.day (-5)
let day_6 = Date.Period.day (-6)

(* Return a date [d] where the day was changed to be the Sunday of the
   week (i.e. the preceding Sunday). *)
let sunday_of_week d =
  match Date.day_of_week d with
  | Date.Sun -> d
  | Date.Mon -> Date.add d day_1
  | Date.Tue -> Date.add d day_2
  | Date.Wed -> Date.add d day_3
  | Date.Thu -> Date.add d day_4
  | Date.Fri -> Date.add d day_5
  | Date.Sat -> Date.add d day_6

let first_day_of_month d =
  Date.make (Date.year d) (Date.int_of_month (Date.month d)) 1

module MW = Map.Make(Date)

(* Add the date [d] and all subsequent weeks until [date_max]
   (excluded) to [m]. *)
let rec add_all_offsets offset d date_max m ~empty_bucket =
  if Date.compare d date_max < 0 then
    let m = if MW.mem d m then m else MW.add d empty_bucket m in
    add_all_offsets offset (offset d) date_max m ~empty_bucket
  else m

let always_true _ = true

let one_week = Date.Period.week 1
let add_one_week d = Date.add d one_week
let minus_one_week = Date.Period.week (-1)
let sub_one_week d = Date.add d minus_one_week

let add_one_month d =
  (* [make] performs the necessary normalization. *)
  Date.make (Date.year d) (Date.int_of_month (Date.month d) + 1)
            (Date.day_of_month d)

let sub_one_month d =
  Date.make (Date.year d) (Date.int_of_month (Date.month d) - 1)
            (Date.day_of_month d)

let timeseries_gen offset ~date_of_value
                   ~empty_bucket ~update_with_value
                   ?start ?stop values =
  let date_for_period, next, prev = match offset with
    | `Week -> sunday_of_week, add_one_week, sub_one_week
    | `Month -> first_day_of_month, add_one_month, sub_one_month in
  (* Add the boundary dates to [m], if they are provided. *)
  let m = ref MW.empty in
  let after_start = match start with
    | Some start -> let start = date_for_period start in
                    (* Make sure this date is in the map: *)
                    m := MW.add start (ref empty_bucket) !m;
                    (fun d -> Date.compare d start >= 0)
    | None -> always_true in
  let before_stop = match stop with
    | Some stop -> let stop = date_for_period stop in
                   if not(after_start stop) then
                     invalid_arg "Cosmetrics.*timeseries: empty range";
                   m := MW.add stop (ref empty_bucket) !m;
                   (fun d -> Date.compare d stop <= 0)
    | None -> always_true in
  let get_bucket date =
    try MW.find date !m
    with Not_found ->
         let bucket = ref empty_bucket in
         if after_start date && before_stop date then
           (* Only add the bucket if within the range. *)
           m := MW.add date bucket !m;
         bucket in
  let add_value v =
    let d = date_for_period(date_of_value v) in
    update_with_value v d ~next ~prev ~get_bucket
  in
  List.iter add_value values;
  let m = MW.map (fun cnt -> !cnt) !m in
  (* Make sure all weeks in the range are present, if needed with a
     count of 0 *)
  let date_min, _ = MW.min_binding m in
  let date_max, _ = MW.max_binding m in
  MW.bindings (add_all_offsets next (next date_min) date_max m
                               ~empty_bucket)


module Commit = struct
  type t = {
      date: Calendar.t;
      author: string;
      sha1: Irmin.Hash.SHA1.t;
    }

  let date t = t.date
  let author t = t.author
  let sha1 t = t.sha1

  let compare c1 c2 = Irmin.Hash.SHA1.compare c1.sha1 c2.sha1
  let hash c = Irmin.Hash.SHA1.hash c.sha1
  let equal c1 c2 = Irmin.Hash.SHA1.equal c1.sha1 c2.sha1

  let of_head t head =
    Irmin.task_of_head (t "task of head") head >>= fun task ->
    let t = Int64.to_float(Irmin.Task.date task) in
    let date = Calendar.from_unixfloat t in
    let author = Irmin.Task.owner task in
    return { date; author; sha1 = head }

  let date_of_commit commit = Calendar.to_date (date commit)

  let update_count _ date ~next ~prev ~get_bucket =
    incr (get_bucket date)

  let timeseries offset ?start ?stop commits =
    timeseries_gen offset ~date_of_value:date_of_commit
                   ~empty_bucket:0  ~update_with_value:update_count
                   ?start ?stop commits

  module StringSet = Set.Make(String)

  let update_authors commit date ~next ~prev ~get_bucket =
    let a = get_bucket date in
    a := StringSet.add (author commit) !a

  let timeseries_author offset ?start ?stop commits =
    let l = timeseries_gen offset ~date_of_value:date_of_commit
                           ~empty_bucket:StringSet.empty
                           ~update_with_value:update_authors
                           ?start ?stop commits in
    List.map (fun (d, a) -> (d, StringSet.cardinal a)) l


  let default_offset = 2
  let default_pencil = [| 0.05; 0.1; 0.2; 0.15; 0.10; 0.05; 0.01 |]

  let update_aliveness pencil offset commit date ~next ~prev ~get_bucket =
    let b = get_bucket (date: Date.t) in
    b := !b +. pencil.(offset);
    let d = ref date in
    for i = -1 downto -offset do
      d := prev !d;
      let b = get_bucket !d in
      b := !b +. pencil.(offset + i)
    done;
    let d = ref date in (* start again from the date of the commit *)
    for i = 1 to Array.length pencil - offset - 1 do
      d := next !d;
      let b = get_bucket !d in
      b := !b +. pencil.(offset + i)
    done

  let squash_into_01 ((n, x) as y) =
    if x >= 1. then (n, 1.)
    else if x <= 0. then (n, 0.)
    else y

  let aliveness period ?start ?stop
                ?(pencil=default_pencil) ?(offset=default_offset)
                commits =
    if offset < 0 then
      invalid_arg "Cosmetrics.Commit.aliveness: offset < 0";
    let n = Array.length pencil in
    if offset >= n then
      invalid_arg(Printf.sprintf "Cosmetrics.Commit.aliveness: offset = %d >= \
                                  %d = length pencil" offset n);
    let l = timeseries_gen period ~date_of_value:date_of_commit
                           ~empty_bucket:0.
                           ~update_with_value:(update_aliveness pencil offset)
                           ?start ?stop commits in
    List.map squash_into_01 l
end

module History = Graph.Persistent.Digraph.ConcreteBidirectional(Commit)

let is_not_merge h c = History.out_degree h c <= 1

let commits ?(merge_commits=false) h =
  let add_commit c l =
    if merge_commits || is_not_merge h c then c :: l
    else l in
  History.fold_vertex add_commit h []

module M = Map.Make(Irmin.Hash.SHA1)

(* Transform the history from Irmin representation to ours. *)
let map_history t h0 =
  (* Collect informations. *)
  let vertices = Irmin.History.fold_vertex (fun n l -> n :: l) h0 [] in
  Lwt_list.map_p (Commit.of_head t) vertices >>= fun vertices ->
  (* Provide an fast access to the vertices. *)
  let m = List.fold_left (fun m c -> M.add c.Commit.sha1 c m) M.empty vertices in
  (* Add vertices & edges to the new graph. *)
  let h = M.fold (fun _ c h -> History.add_vertex h c) m History.empty in
  let add_edge c1 c2 h = History.add_edge h (M.find c1 m) (M.find c2 m) in
  let h = Irmin.History.fold_edges add_edge h0 h in
  return h

let history ?(repo_dir="repo") remote_uri =
  let dir = Filename.basename remote_uri in
  let dir = try Filename.chop_extension dir with _ -> dir in
  let root = Filename.concat repo_dir dir in
  let store = Irmin.basic (module Irmin_unix.Irmin_git.FS)
                          (module Irmin.Contents.String) in
  let config = Irmin_unix.Irmin_git.config ~root ~bare:true () in
  Irmin.create store config Irmin_unix.task >>= fun t ->
  let upstream = Irmin.remote_uri remote_uri in
  catch (fun () -> Irmin.pull_exn (t "Updating") upstream `Update)
        (fun e -> Lwt_io.printlf "Fail pull %s: %s"
                               remote_uri (Printexc.to_string e))
  >>= fun () ->
  Irmin.history (t "history") >>= fun h ->
  map_history t h

module StringMap = Map.Make(String)

module Summary = struct
  type t = {
      n: int;
      pct: float; (* in the interval [0,100] *)
    }

  (* Similar to "git summary".  To each committer, associate the number
     of commits. *)
  let make_map commits =
    let total = ref 0. in
    let add_commit m c =
      total := !total +. 1.;
      let a = Commit.author c in
      try StringMap.add a (StringMap.find a m + 1) m
      with Not_found -> StringMap.add a 1 m in
    let m = List.fold_left add_commit StringMap.empty commits in
    let pct = 100. /. !total in
    StringMap.map (fun n -> { n;  pct = float n *. pct }) m

  let make commits =
    let authors = StringMap.bindings (make_map commits) in
    (* Sort so that more frequent contributors come first. *)
    List.sort (fun (_,s1) (_,s2) -> compare s2.n s1.n) authors
end
