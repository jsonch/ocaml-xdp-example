open Core

let frame_count = 4096
let report_interval = 1_000_000  (* Print stats every 1 million packets *)

let with_socket bind_flags xdp_flags interface queue umem ~f =
  let config =
    Xsk.Socket.
      { Config.default with
        rx_size = frame_count
      ; tx_size = frame_count
      ; xdp_flags
      ; bind_flags
      }
  in
  let socket, rx, tx = Xsk.Socket.create interface queue umem config in
  Exn.protect ~f:(fun () -> f socket rx tx) ~finally:(fun () -> Xsk.Socket.delete socket)
;;

let with_umem frame_size ~f =
  let tmp_filename = Filename.temp_file ~in_dir:"/dev/shm" "bench" "xsk" in
  let fd = Unix.openfile ~mode:[ Unix.O_RDWR ] tmp_filename in
  let mem =
    Exn.protect
      ~f:(fun () -> Bigstring.map_file ~shared:true fd (frame_count * frame_size))
      ~finally:(fun () ->
        Unix.close fd;
        Unix.unlink tmp_filename)
  in
  let config =
    Xsk.Umem.
      { Config.default with frame_size; fill_size = frame_count; comp_size = frame_count }
  in
  let umem, fill, comp = Xsk.Umem.create mem (Bigstring.length mem) config in
  Exn.protect
    ~f:(fun () -> f mem umem fill comp)
    ~finally:(fun () -> Xsk.Umem.delete umem)
;;

let recv_infinite mem fill socket rx frame_size =
  (* Populate the fill queue initially *)
  let addrs = Array.init frame_count ~f:(fun i -> i * frame_size) in
  let fd = Xsk.Socket.fd socket in
  let filled =
    Xsk.Fill_queue.produce_and_wakeup_kernel fill fd addrs ~pos:0 ~nb:frame_count
  in

  if filled <> frame_count then
    failwith (Printf.sprintf "Could not initialize fill queue. Filled %d expected %d" filled frame_count);

  let batch_size = 64 in
  let descs = Array.init frame_count ~f:(fun (_ : int) -> Xsk.Desc.create ()) in

  Stdio.printf "Starting infinite receive loop (reporting every %d packets)...\n%!" report_interval;

  let rec recv_loop total_cnt last_report =
    (* Try to consume from RX queue *)
    match Xsk.Rx_queue.consume rx descs ~pos:0 ~nb:batch_size with
    | 0 ->
      (* No packets available, wake up kernel if needed *)
      if Xsk.Fill_queue.needs_wakeup fill
      then Xsk.Socket.wakeup_kernel_with_sendto socket;
      recv_loop total_cnt last_report
    | rcvd when rcvd < 0 ->
      Stdio.eprintf "ERROR: Negative receive count\n%!";
      recv_loop total_cnt last_report
    | rcvd ->
      (* Process received packets *)
      for i = 0 to rcvd - 1 do
        let desc = Array.unsafe_get descs i in
        Array.unsafe_set addrs i desc.addr;
        (* Touch the packet data to ensure it's actually loaded *)
        if desc.len >= 8
        then ignore (Bigstring.unsafe_get_int64_le_trunc mem ~pos:desc.addr : int)
      done;

      (* Refill the fill queue *)
      let filled = ref (Xsk.Fill_queue.produce_and_wakeup_kernel fill fd addrs ~pos:0 ~nb:rcvd) in
      while !filled <> rcvd do
        filled := Xsk.Fill_queue.produce_and_wakeup_kernel fill fd addrs ~pos:0 ~nb:rcvd
      done;

      let new_total = total_cnt + rcvd in
      let new_last_report =
        if new_total - last_report >= report_interval then (
          Stdio.printf "Received %d packets (total: %d)\n%!" report_interval new_total;
          new_total
        ) else
          last_report
      in
      recv_loop new_total new_last_report
  in
  recv_loop 0 0
;;

let make_flags zero_copy needs_wakeup =
  match zero_copy, needs_wakeup with
  | None, None -> [ Xsk.Bind_flag.XDP_COPY ], [ Xsk.Xdp_flag.XDP_FLAGS_SKB_MODE ]
  | Some zc, None -> [ zc ], [ Xsk.Xdp_flag.XDP_FLAGS_DRV_MODE ]
  | None, Some nw -> [ nw; Xsk.Bind_flag.XDP_COPY ], [ Xsk.Xdp_flag.XDP_FLAGS_SKB_MODE ]
  | Some zc, Some nw -> [ zc; nw ], [ Xsk.Xdp_flag.XDP_FLAGS_DRV_MODE ]
;;

let command =
  Command.basic
    ~summary:"Receive an infinite stream of packets via AF_XDP"
    Command.Let_syntax.(
      let open Command.Param in
      let%map interface = flag "-d" (required string) ~doc:"device Device to receive on"
      and queue = flag "-q" (required int) ~doc:"queue_id Queue to bind to"
      and frame_size =
        flag "-f" (optional_with_default 2048 int) ~doc:"n Size of each frame in the umem"
      and zero_copy =
        flag "-z" (no_arg_some Xsk.Bind_flag.XDP_ZEROCOPY) ~doc:"Enable zero copy mode"
      and needs_wakeup =
        flag
          "-w"
          (no_arg_some Xsk.Bind_flag.XDP_USE_NEED_WAKEUP)
          ~doc:"Enable the XDP_USE_NEED_WAKEUP flag"
      in
      fun () ->
        let bf, xdpf = make_flags zero_copy needs_wakeup in
        with_umem frame_size ~f:(fun mem umem fill (_ : Xsk.Comp_queue.t) ->
            with_socket bf xdpf interface queue umem ~f:(fun socket rx (_ : Xsk.Tx_queue.t) ->
                recv_infinite mem fill socket rx frame_size)))
;;

let () = Command.run command
