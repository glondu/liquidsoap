(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2023 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

module Fps = struct
  type filter = {
    time_base : Avutil.rational;
    input : [ `Video ] Avfilter.input;
    output : [ `Video ] Avfilter.output;
  }

  type t = [ `Filter of filter | `Pass_through of Avutil.rational ]

  let time_base = function
    | `Filter { time_base } -> time_base
    | `Pass_through time_base -> time_base

  let init ?start_pts ~width ~height ~pixel_format ~time_base ?pixel_aspect
      ?source_fps ~target_fps () =
    let config = Avfilter.init () in
    let _buffer =
      let args =
        [
          `Pair ("video_size", `String (Printf.sprintf "%dx%d" width height));
          `Pair ("pix_fmt", `Int (Avutil.Pixel_format.get_id pixel_format));
          `Pair ("time_base", `Rational time_base);
        ]
        @
        match pixel_aspect with
          | None -> []
          | Some p -> [`Pair ("pixel_aspect", `Rational p)]
      in
      let args =
        match source_fps with
          | None -> args
          | Some fps ->
              `Pair ("frame_rate", `Rational { Avutil.num = fps; den = 1 })
              :: args
      in
      Avfilter.attach ~name:"buffer" ~args Avfilter.buffer config
    in
    (* There are two use-case:
       - Decoder assumes no `start_pts` and want to keep negative
         STARTPTS (to be skipped) but re-align positive STARTPTS
         in case the file is a partial copy dump.
       - Encoder wants to apply `start_pts` all the time and realign
         all PTS accordingly. *)
    let setpts =
      match
        List.find_opt
          (fun { Avfilter.name } -> name = "setpts")
          Avfilter.filters
      with
        | Some setpts -> setpts
        | None -> failwith "Could not find setpts ffmpeg filter!"
    in
    let setpts =
      let args =
        match start_pts with
          | Some start_pts ->
              [
                `Pair
                  ("expr", `String (Printf.sprintf "%Ld+PTS-STARTPTS" start_pts));
              ]
          | None -> [`Pair ("expr", `String "PTS-min(STARTPTS, 0)")]
      in
      Avfilter.attach ~name:"setpts" ~args setpts config
    in
    let fps =
      match
        List.find_opt (fun { Avfilter.name } -> name = "fps") Avfilter.filters
      with
        | Some fps -> fps
        | None -> failwith "Could not find fps ffmpeg filter!"
    in
    let fps =
      let args =
        [`Pair ("fps", `Rational { Avutil.num = target_fps; den = 1 })]
      in
      let args =
        if start_pts = None then `Pair ("start_time", `Int 0) :: args else args
      in
      Avfilter.attach ~name:"fps" ~args fps config
    in
    let _buffersink =
      Avfilter.attach ~name:"buffersink" Avfilter.buffersink config
    in
    Avfilter.link
      (List.hd Avfilter.(_buffer.io.outputs.video))
      (List.hd Avfilter.(setpts.io.inputs.video));
    Avfilter.link
      (List.hd Avfilter.(setpts.io.outputs.video))
      (List.hd Avfilter.(fps.io.inputs.video));
    Avfilter.link
      (List.hd Avfilter.(fps.io.outputs.video))
      (List.hd Avfilter.(_buffersink.io.inputs.video));
    let graph = Avfilter.launch config in
    let _, input = List.hd Avfilter.(graph.inputs.video) in
    let _, output = List.hd Avfilter.(graph.outputs.video) in
    let time_base = Avfilter.(time_base output.context) in
    { input; output; time_base }

  (* Source fps is not always known so it is optional here. *)
  let init ?start_pts ~width ~height ~pixel_format ~time_base ?pixel_aspect
      ?source_fps ~target_fps () =
    match source_fps with
      | Some f when f = target_fps -> `Pass_through time_base
      | _ ->
          `Filter
            (init ?start_pts ~width ~height ~pixel_format ~time_base
               ?pixel_aspect ?source_fps ~target_fps ())

  let rec flush cb output =
    try
      cb (output.Avfilter.handler ());
      flush cb output
    with Avutil.Error `Eagain -> ()

  let convert converter frame cb =
    match converter with
      | `Pass_through _ -> cb frame
      | `Filter { input; output } ->
          Avutil.Frame.set_pts frame (Avutil.Frame.pts frame);
          input (`Frame frame);
          flush cb output

  let eof converter cb =
    match converter with
      | `Pass_through _ -> ()
      | `Filter { input; output } -> (
          input `Flush;
          try flush cb output with Avutil.Error `Eof -> ())
end
