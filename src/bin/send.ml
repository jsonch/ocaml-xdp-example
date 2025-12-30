open Core

let frame_count = 4096

type%cstruct ethernet =
  { dst : uint8_t [@len 6]
  ; src : uint8_t [@len 6]
  ; ethertype : uint16_t
  }
[@@big_endian]

type%cstruct ipv4 =
  { hlen_version : uint8_t
  ; tos : uint8_t
  ; len : uint16_t
  ; id : uint16_t
  ; off : uint16_t
  ; ttl : uint8_t
  ; proto : uint8_t
  ; csum : uint16_t
  ; src : uint8_t [@len 4]
  ; dst : uint8_t [@len 4]
  }
[@@big_endian]

type%cstruct udp4 =
  { src_port : uint16_t
  ; dst_port : uint16_t
  ; len : uint16_t
  ; csum : uint16_t
  }
[@@big_endian]

let mac_of_string str =
  str
  |> String.split ~on:':'
  |> fun l ->
  if List.length l <> 6
  then raise (Invalid_argument "invalid mac address")
  else
    l
    |> List.map ~f:(fun s -> String.concat [ "0x"; s ])
    |> List.map ~f:Int.of_string
    |> List.map ~f:Char.of_int_exn
    |> String.of_char_list
;;

let ip_of_string str =
  str
  |> String.split ~on:'.'
  |> fun l ->
  if List.length l <> 4
  then raise (Invalid_argument "invalid ip address")
  else
    l |> List.map ~f:Int.of_string |> List.map ~f:Char.of_int_exn |> String.of_char_list
;;

let set_pkt ~src_mac ~dst_mac ~src_ip ~dst_ip pkt pos =
  let ether = Cstruct.create sizeof_ethernet in
  let src_ether_addr = mac_of_string src_mac in
  let dst_ether_addr = mac_of_string dst_mac in
  set_ethernet_src src_ether_addr 0 ether;
  set_ethernet_dst dst_ether_addr 0 ether;
  set_ethernet_ethertype ether 0x800;

  let ip = Cstruct.create sizeof_ipv4 in
  let src_ip_addr = ip_of_string (Host_and_port.host src_ip) in
  let dst_ip_addr = ip_of_string (Host_and_port.host dst_ip) in
  set_ipv4_hlen_version ip 0x45;
  set_ipv4_tos ip 0;
  set_ipv4_len ip 20;
  set_ipv4_id ip 0;
  set_ipv4_off ip 0;
  set_ipv4_ttl ip 255;
  set_ipv4_proto ip 17;
  set_ipv4_csum ip 0;
  set_ipv4_dst dst_ip_addr 0 ip;
  set_ipv4_src src_ip_addr 0 ip;
  let csum = ref 0xFFFF in
  for i = 0 to 9 do
    csum := !csum + Cstruct.BE.get_uint16 ip (2 * i);
    if !csum > 0xFFFF then csum := !csum - 0xFFFF
  done;
  csum := lnot !csum;
  set_ipv4_csum ip !csum;

  let udp = Cstruct.create sizeof_udp4 in
  let src_port = Host_and_port.port src_ip in
  let dst_port = Host_and_port.port dst_ip in
  let data_len = 8 in
  set_udp4_src_port udp src_port;
  set_udp4_dst_port udp dst_port;
  set_udp4_len udp (sizeof_udp4 + data_len);
  set_udp4_csum udp 0;

  let buf = Cstruct.create data_len in
  Cstruct.LE.set_uint64 buf 0 (Int64.of_int pos);
  let data = Cstruct.concat [ ether; ip; udp; buf ] in
  Base_bigstring.From_bytes.blit
    ~src:(Cstruct.to_bytes data)
    ~src_pos:0
    ~dst:pkt
    ~dst_pos:pos
    ~len:(Cstruct.len data)
;;

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
      ~finally:(fun () -> Unix.unlink tmp_filename)
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

let populate_frames ~mem ~frame_size ~src_mac ~dst_mac ~src_ip ~dst_ip =
  let rec loop pos =
    if pos >= Base_bigstring.length mem
    then ()
    else (
      set_pkt ~src_mac ~dst_mac ~src_ip ~dst_ip mem pos;
      loop (pos + frame_size))
  in
  loop 0
;;

let send_infinite frame_size cq socket txq =
  let fd = Xsk.Socket.fd socket in
  let max_batch_size = Int.min frame_count 64 in
  let pkt_len = sizeof_ethernet + sizeof_ipv4 + sizeof_udp4 + 8 in
  let descs =
    Array.init max_batch_size ~f:(fun i ->
        let desc = Xsk.Desc.create () in
        desc.addr <- frame_size * i;
        desc.len <- pkt_len;
        desc)
  in
  let addrs = Array.create ~len:max_batch_size 0 in

  Stdio.printf "Starting infinite send loop...\n%!";

  let rec tx_loop sent consumed =
    (* Wait for socket to be writeable *)
    if not (Xsk.Socket.pollout socket 100)
    then tx_loop sent consumed
    else (
      (* Calculate how many frames are available in UMEM *)
      let tx_batch_size = Int.min max_batch_size (frame_count - (sent - consumed)) in

      let sent =
        if tx_batch_size > 0 then (
          (* Send a batch *)
          for i = 0 to tx_batch_size - 1 do
            let pos = (sent + i) land (frame_count - 1) in
            (Array.unsafe_get descs i).Xsk.Desc.addr <- pos * frame_size
          done;
          let sent_now = ref 0 in
          while !sent_now = 0 do
            sent_now := Xsk.Tx_queue.produce_and_wakeup_kernel txq fd descs ~pos:0 ~nb:tx_batch_size
          done;
          sent + !sent_now
        ) else (
          (* No frames available, wake up kernel *)
          Xsk.Socket.wakeup_kernel_with_sendto socket;
          sent
        )
      in

      (* Consume completed frames to free up UMEM *)
      let consumed0 = Xsk.Comp_queue.consume cq addrs ~pos:0 ~nb:max_batch_size in
      tx_loop sent (consumed + consumed0))
  in
  tx_loop 0 0
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
    ~summary:"Send an infinite stream of UDP packets via AF_XDP"
    Command.Let_syntax.(
      let open Command.Param in
      let%map interface = flag "-d" (required string) ~doc:"device Device to transmit on"
      and queue = flag "-q" (required int) ~doc:"queue_id Queue to bind to"
      and frame_size =
        flag "-f" (optional_with_default 2048 int) ~doc:"n Size of each frame in the umem"
      and src_ip =
        flag
          "-sip"
          (required host_and_port)
          ~doc:"source_ip Source IP:port (e.g., 10.100.1.1:9999)"
      and dst_ip =
        flag
          "-dip"
          (required host_and_port)
          ~doc:"destination_ip Destination IP:port (e.g., 10.100.1.2:9999)"
      and src_mac =
        flag
          "-smac"
          (required string)
          ~doc:"source_mac Source MAC address (e.g., 02:00:00:00:00:01)"
      and dst_mac =
        flag
          "-dmac"
          (required string)
          ~doc:"destination_mac Destination MAC address (e.g., 02:00:00:00:00:02)"
      and zero_copy =
        flag "-z" (no_arg_some Xsk.Bind_flag.XDP_ZEROCOPY) ~doc:"Enable zero copy mode"
      and needs_wakeup =
        flag
          "-w"
          (no_arg_some Xsk.Bind_flag.XDP_USE_NEED_WAKEUP)
          ~doc:"Enable the XDP_USE_NEED_WAKEUP flag"
      in
      let bind_flags, xdp_flags = make_flags zero_copy needs_wakeup in
      fun () ->
        with_umem frame_size ~f:(fun mem umem (_ : Xsk.Fill_queue.t) comp ->
            with_socket
              bind_flags
              xdp_flags
              interface
              queue
              umem
              ~f:(fun socket (_ : Xsk.Rx_queue.t) txq ->
                populate_frames ~mem ~frame_size ~src_mac ~dst_mac ~src_ip ~dst_ip;
                send_infinite frame_size comp socket txq)))
;;

let () = Command.run command
