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

(** Connect sources to FFmpeg filters. *)

exception Not_ready

let noop () = ()

type 'a _duration_converter = {
  idx : int64;
  time_base : Avutil.rational;
  converter : 'a Avutil.Frame.t Ffmpeg_utils.Duration.t;
}

let track_mark_metadata = "liquidsoap_track_mark"

class virtual ['a] duration_converter =
  object (self)
    method virtual log : Log.t
    val mutable duration_converter : 'a _duration_converter option = None
    val mutable last_duration : int64 option = None

    method convert_duration ~stream_idx ~convert_ts ~time_base frame =
      let duration_converter =
        match duration_converter with
          | Some { idx; time_base = converter_time_base; converter }
            when idx = stream_idx && time_base = converter_time_base ->
              converter
          | _ ->
              let last_ts, offset =
                match duration_converter with
                  | None -> (None, 0L)
                  | Some { idx; converter } ->
                      if idx = stream_idx then
                        self#log#important "Unexpected time_base change!";
                      let last_ts = Ffmpeg_utils.Duration.last_ts converter in
                      let frame_ts =
                        Option.value ~default:0L (Avutil.Frame.pts frame)
                      in
                      let position =
                        Int64.add
                          (Option.value ~default:0L last_ts)
                          (Option.value ~default:0L last_duration)
                      in
                      let offset = Int64.sub position frame_ts in
                      (last_ts, offset)
              in
              let converter =
                Ffmpeg_utils.Duration.init ~offset ?last_ts ~mode:`PTS
                  ~src:time_base ~convert_ts ~get_ts:Avutil.Frame.pts
                  ~set_ts:Avutil.Frame.set_pts ()
              in
              duration_converter <-
                Some { idx = stream_idx; time_base; converter };
              converter
      in
      last_duration <- Avutil.Frame.duration frame;
      Ffmpeg_utils.Duration.push duration_converter frame
  end

class virtual ['a] base_output ~pass_metadata ~name ~frame_t ~field source =
  object (self)
    inherit
      Output.output
        ~infallible:false ~on_stop:noop ~on_start:noop ~name
          ~output_kind:"ffmpeg.filter.input" (Lang.source source) true as super

    inherit ['a] duration_converter
    inherit! Source.no_seek

    initializer
      Typing.(
        self#frame_type <: frame_t;
        source#frame_type <: self#frame_type)

    val mutable input : [ `Frame of 'a Avutil.frame | `Flush ] -> unit =
      fun _ -> ()

    method set_input fn = input <- fn
    val mutable init : 'a Avutil.frame -> unit = fun _ -> assert false
    method set_init v = init <- v
    method start = ()
    method stop = ()
    method! reset = ()
    val mutable is_up = false
    method! is_ready = is_up && super#is_ready

    method! wake_up l =
      is_up <- true;
      super#wake_up l

    method! sleep =
      is_up <- false;
      super#sleep

    method virtual raw_ffmpeg_frames
        : Content.data -> 'a Ffmpeg_raw_content.frame list

    method send_frame memo =
      let content = Frame.get memo field in
      let frames = self#raw_ffmpeg_frames content in
      (match frames with
        | { Ffmpeg_raw_content.frame } :: _ -> init frame
        | _ -> ());
      List.iter
        (fun { Ffmpeg_raw_content.frame; time_base; stream_idx } ->
          match
            self#convert_duration ~convert_ts:true ~stream_idx ~time_base frame
          with
            | None -> ()
            | Some (_, frames) ->
                List.iteri
                  (fun pos (_, frame) ->
                    if pos = 0 then (
                      let metadata =
                        if pass_metadata then (
                          (* Pass only one metadata. *)
                          match Frame.get_all_metadata memo with
                            | (_, m) :: _ ->
                                Hashtbl.fold (fun k v m -> (k, v) :: m) m []
                            | _ -> [])
                        else []
                      in
                      let metadata =
                        if
                          Frame.is_partial memo
                          || List.length (Frame.breaks memo) > 1
                        then (track_mark_metadata, "1") :: metadata
                        else metadata
                      in
                      if metadata <> [] then
                        Avutil.Frame.set_metadata frame metadata);
                    input (`Frame frame))
                  frames)
        frames
  end

(** From the script perspective, the operator sending data to a filter graph
  * is an output. *)
class audio_output ~pass_metadata ~name ~frame_t ~field source =
  object
    inherit [[ `Audio ]] base_output ~pass_metadata ~name ~frame_t ~field source

    method raw_ffmpeg_frames content =
      List.map snd Ffmpeg_raw_content.((Audio.get_data content).AudioSpecs.data)
  end

class video_output ~pass_metadata ~name ~frame_t ~field source =
  object
    inherit [[ `Video ]] base_output ~pass_metadata ~name ~frame_t ~field source

    method raw_ffmpeg_frames content =
      List.map snd Ffmpeg_raw_content.((Video.get_data content).VideoSpecs.data)
  end

class virtual ['a] input_base ~name ~pass_metadata ~self_sync_type ~self_sync
  ~is_ready ~pull frame_t =
  let stream_idx = Ffmpeg_content_base.new_stream_idx () in
  object (self)
    inherit ['a] duration_converter
    inherit Source.source ~name ()
    inherit Source.no_seek
    initializer Typing.(self#frame_type <: frame_t)
    method stype : Source.source_t = `Fallible
    method remaining = Generator.remaining self#buffer
    method abort_track = ()
    method virtual buffer : Generator.t

    method virtual put_data
        : length:int -> (int * 'a Ffmpeg_raw_content.frame) list -> unit

    val mutable output = None

    method private flush_buffer output =
      let time_base = Avfilter.(time_base output.context) in
      fun () ->
        let frame = output.Avfilter.handler () in
        if pass_metadata then (
          let metadata = Avutil.Frame.metadata frame in
          if metadata <> [] then (
            let m = Hashtbl.create (List.length metadata) in
            List.iter
              (fun (k, v) -> if k <> track_mark_metadata then Hashtbl.add m k v)
              metadata;
            Generator.add_metadata self#buffer m;
            if List.mem_assoc track_mark_metadata metadata then
              Generator.add_track_mark self#buffer));
        match
          self#convert_duration ~convert_ts:false ~stream_idx ~time_base frame
        with
          | Some (length, frames) ->
              let frames =
                List.map
                  (fun (pos, frame) ->
                    (pos, { Ffmpeg_raw_content.time_base; stream_idx; frame }))
                  frames
              in
              self#put_data ~length frames
          | None -> ()

    method self_sync : Source.self_sync =
      (Lazy.force self_sync_type, self_sync ())

    method pull =
      try
        (* Init is driven by the pull. *)
        let output =
          while output = None do
            if not (is_ready ()) then raise Not_ready;
            pull ()
          done;
          Option.get output
        in
        let flush = self#flush_buffer output in
        let rec f () =
          try
            while true do
              flush ()
            done
          with Avutil.Error `Eagain ->
            if
              Generator.length self#buffer < Lazy.force Frame.size
              && is_ready ()
            then (
              pull ();
              f ())
        in
        f ()
      with Not_ready -> ()

    method is_ready =
      Generator.length self#buffer >= Lazy.force Frame.size || is_ready ()

    method private get_frame frame =
      let b = Frame.breaks frame in
      if Generator.length self#buffer < Lazy.force Frame.size then self#pull;
      Generator.fill self#buffer frame;
      if List.length b + 1 <> List.length (Frame.breaks frame) then (
        let cur_pos = Frame.position frame in
        Frame.set_breaks frame (b @ [cur_pos]))
  end

type audio_config = {
  format : Avutil.Sample_format.t;
  rate : int;
  channels : int;
}

(* Same thing here. *)
class audio_input ~field ~self_sync_type ~self_sync ~is_ready ~pull
  ~pass_metadata frame_t =
  object (self)
    inherit
      [[ `Audio ]] input_base
        ~name:"ffmpeg.filter.audio.output" ~pass_metadata ~self_sync_type
          ~self_sync ~is_ready ~pull frame_t

    initializer Typing.(self#frame_type <: frame_t)

    method set_output v =
      let output_format =
        {
          Ffmpeg_raw_content.AudioSpecs.channel_layout =
            Some Avfilter.(channel_layout v.context);
          sample_rate = Some Avfilter.(sample_rate v.context);
          sample_format = Some Avfilter.(sample_format v.context);
        }
      in
      Content.merge
        (Option.get
           (Frame.Fields.find_opt Frame.Fields.audio self#content_type))
        (Ffmpeg_raw_content.Audio.lift_params output_format);
      output <- Some v

    method put_data ~length =
      function
      | [] -> ()
      | (_, frame) :: _ as data ->
          let params = Ffmpeg_raw_content.AudioSpecs.frame_params frame in
          let content =
            { Ffmpeg_raw_content.AudioSpecs.params; data; length }
          in
          Generator.put self#buffer field
            (Ffmpeg_raw_content.Audio.lift_data content)
  end

type video_config = {
  width : int;
  height : int;
  pixel_format : Avutil.Pixel_format.t;
}

class video_input ~field ~self_sync_type ~self_sync ~is_ready ~pull
  ~pass_metadata frame_t =
  object (self)
    inherit
      [[ `Video ]] input_base
        ~name:"ffmpeg.filter.video.output" ~pass_metadata ~self_sync_type
          ~self_sync ~is_ready ~pull frame_t

    method set_output v =
      let output_format =
        {
          Ffmpeg_raw_content.VideoSpecs.width = Some Avfilter.(width v.context);
          height = Some Avfilter.(height v.context);
          pixel_format = Some Avfilter.(pixel_format v.context);
          pixel_aspect = Avfilter.(pixel_aspect v.context);
        }
      in
      Content.merge
        (Option.get
           (Frame.Fields.find_opt Frame.Fields.video self#content_type))
        (Ffmpeg_raw_content.Video.lift_params output_format);
      output <- Some v

    method put_data ~length =
      function
      | [] -> ()
      | (_, frame) :: _ as data ->
          let params = Ffmpeg_raw_content.VideoSpecs.frame_params frame in
          let content =
            { Ffmpeg_raw_content.VideoSpecs.params; data; length }
          in
          Generator.put self#buffer field
            (Ffmpeg_raw_content.Video.lift_data content)
  end
