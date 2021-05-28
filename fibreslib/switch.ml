exception Multiple_exceptions of exn list

exception Cancelled of exn

let () =
  Printexc.register_printer @@ function
  | Multiple_exceptions exns -> Some ("Multiple exceptions:\n" ^ String.concat "\nand\n" (List.map Printexc.to_string exns))
  | Cancelled ex -> Some ("Cancelled: " ^ Printexc.to_string ex)
  | _ -> None

type state =
  | On of (exn -> unit) Lwt_dllist.t
  | Off of exn
  | Finished

type t = {
  id : Ctf.id;
  mutable state : state;
  mutable fibres : int;
  mutable extra_exceptions : exn list;
  waiter : unit Waiters.t;
}

effect Await : t option * Ctf.id * 'a Waiters.t -> 'a

let await ?sw waiters id =
  perform (Await (sw, id, waiters))

let check t =
  match t.state with
  | On _ -> ()
  | Off ex -> raise (Cancelled ex)
  | Finished -> invalid_arg "Switch finished!"

let turn_off t ex =
  match t.state with
  | Finished -> invalid_arg "Switch finished!"
  | Off orig when orig == ex -> ()
  | Off _ ->
    begin match ex with
      | Cancelled _ -> ()       (* The original exception will be reported elsewhere *)
      | _ -> t.extra_exceptions <- ex :: t.extra_exceptions
    end
  | On q ->
    Ctf.note_resolved t.id ~ex:(Some ex);
    t.state <- Off ex;
    Lwt_dllist.iter_r (fun f -> f ex) q

let add_cancel_hook t hook =
  match t.state with
  | Finished -> invalid_arg "Switch finished!"
  | Off ex -> hook ex; ignore
  | On q ->
    let node = Lwt_dllist.add_r hook q in
    (fun () -> Lwt_dllist.remove node)

let add_cancel_hook_opt t hook =
  match t with
  | Some t -> add_cancel_hook t hook
  | None -> ignore

let with_op t fn =
  check t;
  t.fibres <- t.fibres + 1;
  Fun.protect fn
    ~finally:(fun () ->
        t.fibres <- t.fibres - 1;
        if t.fibres = 0 then
          Waiters.wake_all t.waiter (Ok ())
      )

let await_idle t =
  while t.fibres > 0 do
    Ctf.note_try_read t.id;
    await t.waiter t.id
  done

let raise_with_extras t ex =
  match t.extra_exceptions with
  | [] -> raise ex
  | exns -> raise (Multiple_exceptions (ex :: List.rev exns))

let top fn =
  let id = Ctf.mint_id () in
  Ctf.note_created id Ctf.Switch;
  let q = Lwt_dllist.create () in
  let t = {
    id;
    state = On q;
    fibres = 0;
    extra_exceptions = [];
    waiter = Waiters.create ();
  } in
  match fn t with
  | v ->
    await_idle t;
    begin match t.state with
      | Finished -> assert false
      | On _ ->
        (* Success. Just mark the switch as unusable now. *)
        t.state <- Finished;
        Ctf.note_read t.id;
        v
      | Off ex ->
        (* Function succeeded, but got failure waiting for fibres to finish. *)
        t.state <- Finished;
        Ctf.note_read t.id;
        raise_with_extras t ex
    end
  | exception ex ->
    (* Main function failed.
       Turn the switch off to cancel any running fibres, if it's not off already. *)
    turn_off t ex;
    await_idle t;
    Ctf.note_read t.id;
    match t.state with
    | On _ | Finished -> assert false
    | Off ex ->
      t.state <- Finished;
      raise_with_extras t ex

let sub ~sw ~on_error fn =
  let w = ref ignore in
  match
    top (fun child ->
        w := add_cancel_hook sw (turn_off child);
        try fn child
        with ex -> turn_off child ex; raise ex
      )
  with
  | v ->
    Waiters.remove_waiter !w;
    v
  | exception ex ->
    Waiters.remove_waiter !w;
    on_error ex