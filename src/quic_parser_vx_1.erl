%%%-------------------------------------------------------------------
%%% @author alex
%%% @copyright (C) 2018, alex
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(quic_parser_vx_1).

%% API
-export([parse_frames/1]).

-compile(inline).

-include("quic_headers.hrl").
-include("quic_vx_1.hrl").


-spec parse_frames(Payload) -> Result when
    Payload :: binary(),
    Result :: {Frames, Acks, TLS_Frame} |
              {error, Reason},
    Frames :: [quic_frame()],
    Acks :: [quic_frame()],
    TLS_Frame :: [quic_frame()],
    Reason :: gen_quic:error().

parse_frames(<<Frames/binary>>) ->
  io:format("Frames: ~p~n", [Frames]),
  parse_frame(Frames, []).

%% These functions are the list of functions to call when a specific type is 
%% parsed. This enables the entire packet to be parsed with optimized 
%% sub-binary creation and allows for easy changes to the frame headers.
%% The list must be of valid function names. The dispatch function is 
%% parse_next.
%% Custom function entries must be added to the parse_next case statement.
%% The last function call should always be parse_frame unless the entire 
%% packet is parsed.
%% Potentially move all of these into a different module.

%% Padding and Ping just loop back to parse_frame.
padding() -> [parse_frame].

ping() -> [parse_frame].

%% Conn_Close and App_Close read an error, message length, and message.
conn_close() -> 
  [parse_conn_error, 
   parse_message, 
   parse_frame].

app_close() -> 
  [parse_app_error, 
   parse_message, 
   parse_frame].

%% Reset Stream reads a stream_id, app_error, and last stream offset.
rst_stream() -> 
  [parse_var_length, 
   parse_app_error, 
   parse_var_length, 
   parse_frame].

%% Max_Data and Max_Stream_ID read a variable integer, respectively.
max_data() -> 
  [parse_var_length, 
   parse_frame].

max_stream_id() -> 
  [parse_var_length, 
   parse_frame].

%% Max_Stream_Data parses the stream ID and data limit.
max_stream_data() -> 
  [parse_var_length, 
   parse_var_length, 
   parse_frame].

%% Blocked and Stream_ID_Blocked reads the wanted value above limit.
data_blocked() -> 
  [parse_var_length, 
   parse_frame].

stream_id_blocked() -> 
  [parse_var_length, 
   parse_frame].

%% Stream_Data_Blocked reads the stream ID and the blocked value.
stream_data_blocked() -> 
  [parse_var_length,
   parse_var_length,
   parse_frame].

%% New_Conn_ID reads a sequence number and a new connection ID with the
%% 128 bit stateless retry token.
new_conn_id() -> 
  [parse_conn_len,
   parse_var_length,
   parse_conn_id,
   parse_token,
   parse_frame].

%% Stop_Sending reads a stream id and app error code
stop_sending() -> 
  [parse_var_length, 
   parse_app_error,
   parse_frame].

%% retire_conn_id has a single sequence number of variable length
retire_conn_id() ->
  [parse_var_length,
   parse_frame].

%% ack_frame reads the largest ack in the ack block, the ack_delay, and the
%% number of blocks/gaps in the ack_block then parses the ack_block.
ack_frame() -> 
  [parse_var_length, 
   parse_var_length,
   parse_var_length,
   parse_ack_blocks,
   add_end_ack,
   parse_frame].

%% same as ack_frame, but with the ecn block added.
ack_frame_ecn() -> 
  [parse_var_length, 
   parse_var_length,
   parse_var_length,
   parse_ack_blocks,
   add_end_ack,
   parse_var_length,
   parse_var_length,
   parse_var_length,
   add_end_ecn,
   parse_frame].

%% Path_Challenge and Path_Response read the 64 bit random Nonce for
%% the path challenge and response protocol.
path_challenge() -> 
  [parse_challenge, 
   parse_frame].

path_response() -> 
  [parse_challenge, 
   parse_frame].

crypto_frame() ->
  [parse_var_length,
   parse_message,
   parse_frame].

%% The streams have different headers so the stream event list has 
%% the argument {Offset, Length, Fin} to indicate if the relevant bits are set.
%% New stream with the remainder of the packet being the stream message.

stream({Offset, Length}) -> 
  [parse_var_length] ++ stream_offset(Offset) ++ stream_length(Length).

%% If the offset bit is set, there is a variable length offset in the frame header.
stream_offset(0) -> [];
stream_offset(1) -> [parse_var_length].

%% If the length bit is not set, the remainder of the packet is the message.
%% So no looping back to parse_frame.
stream_length(0) -> [validate_packet];
stream_length(1) -> [parse_var_length, parse_message, parse_frame].

%% The parse_next function is a dispatch function that calls the next item to
%% parse in the frame header. This is necessary so that the sub-binary
%% optimizations can be utilized. Calling Fun(Packet, ...) is too dynamic for the
%% compiler to allow the optimizations.

-spec parse_next(bitstring(), [term()], [atom()]) -> Result when
    Result :: {ok, [quic_frame()], [quic_frame()], [quic_frame()]} |
              {error, term()}.

parse_next(<<Packet/bits>>, Acc, [Next_Fun | Funs]) ->
  case Next_Fun of
    add_end_ecn ->
      %% Adds an atom to indicate the presence of ecn info.
      parse_next(Packet, [end_ecn | Acc], Funs);

    add_end_ack ->
      %% This adds an atom to the stack to indicate the end of an ack block.
      parse_next(Packet, [end_ack_block | Acc], Funs);

    validate_packet ->
      validate_packet(Packet, Acc, Funs);

    parse_frame ->
      parse_frame(Packet, Acc);

    parse_var_length ->
      parse_var_length(Packet, Acc, Funs);

    parse_conn_len ->
      parse_conn_len(Packet, Acc, Funs);

    parse_conn_id ->
      parse_conn_id(Packet, Acc, Funs);

    parse_conn_error ->
      parse_conn_error(Packet, Acc, Funs);

    parse_app_error ->
      parse_app_error(Packet, Acc, Funs);

    parse_message ->
      parse_message(Packet, Acc, Funs);

    parse_ack_blocks ->
      parse_ack_blocks(Packet, Acc, Funs);

    parse_token ->
      parse_token(Packet, Acc, Funs)
  end;

parse_next(<<>>, __Acc, _Funs) ->
  {error, protocol_violation}.


-spec validate_packet(binary(), [term()], list()) -> Result when
    Result :: {ok, [quic_frame()], [quic_frame()], [quic_frame()]} |
              {error, term()}.

%% Called when the stream uses the remainder of the packet
%% If any funs are remaining, a protocol violation error is thrown.
%% TODO: Needs different name.
validate_packet(<<Message/binary>>, Stack, []) ->
  validate_packet([Message | Stack]);

validate_packet(_Other, _Stack, _Funs) ->
  {error, protocol_violation}.

%% Crawls through the Stack and places items into the correct records.
%% Pushes onto Acc (putting the payload back in order)
%% Returns when stack is empty.

-spec validate_packet([term()]) -> Result when
    Result :: {ok, [quic_frame()], [quic_frame()], [quic_frame()]}.

validate_packet(Stack) ->
  validate_packet(Stack, [], [], []).

-spec validate_packet([term()], [quic_frame()], [quic_frame()], [quic_frame()]) -> 
                         Result when
    Result :: {ok, [quic_frame()], [quic_frame()], [quic_frame()]}.

validate_packet([], Frames, Ack_Frames, TLS_Info) ->
  {ok, Frames, Ack_Frames, TLS_Info};

%% 0 - item frames
validate_packet([ping | Rest], Acc, Ack_Frames, TLS_Info) ->
  validate_packet(Rest, [#{type => ping} | Acc], Ack_Frames, TLS_Info);


%% 1 - item frames
validate_packet([Max_Data, max_data | Rest], Acc, Ack_Frames, TLS_Info) ->
  Frame = #{
            type => max_data, 
            max_data => Max_Data
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Max_ID, max_stream_id | Rest], Acc, Ack_Frames, TLS_Info) ->
  Frame = #{
            type => max_stream_id, 
            max_stream_id => Max_ID
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Offset, data_blocked | Rest], Acc, Ack_Frames, TLS_Info) ->
  Frame = #{
            type => data_blocked, 
            offset => Offset
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Stream_ID, stream_id_blocked | Rest], Acc, Ack_Frames, TLS_Info) ->
  Frame = #{
            type => stream_id_blocked, 
            stream_id => Stream_ID
            },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Challenge, path_challenge | Rest], Acc, Ack_Frames, TLS_Info) ->
  Frame = #{
            type => path_challenge, 
            challenge => Challenge
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Challenge, path_response | Rest], Acc, Ack_Frames, TLS_Info) ->
  Frame = #{
            type => path_response, 
            challenge => Challenge
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Sequence, retire_conn_id | Rest], Acc, Ack_Frames, TLS_Info) ->
  Frame = #{ type => retire_conn_id,
             sequence => Sequence},
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

%% 2 - item frames
validate_packet([Crypto_Bin, Length, Offset, crypto_frame | Rest],
                Acc, Ack_Frames, TLS_Info) ->
  Frame = #{type => crypto,
            offset => Offset,
            length => Length,
            binary => Crypto_Bin},
  validate_packet(Rest, Acc, Ack_Frames, [Frame | TLS_Info]);

validate_packet([App_Error, Stream_ID, stop_sending | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  Frame = #{
            type => stop_sending, 
            stream_id => Stream_ID, 
            error_code => App_Error
           },

  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Offset, Stream_ID, stream_data_blocked | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  <<_:60, Type:1, Owner:1>> = <<Stream_ID:62>>,

  Frame = #{
            type => stream_data_blocked,
            stream_id => Stream_ID,
            offset => Offset,
            stream_owner => Owner,
            stream_type => Type
           },

  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Max_Stream_Data, Stream_ID, max_stream_data | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  <<_:60, Type:1, Owner:1>> = <<Stream_ID:62>>,

  Frame = #{
            type => max_stream_data,
            stream_id => Stream_ID,
            max_stream_data => Max_Stream_Data,
            stream_owner => Owner,
            stream_type => Type
           },

  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Message, App_Error, app_close | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  Frame = #{
            type => app_close, 
            error_code => App_Error, 
            error_message => Message
           },

  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Message, Conn_Error, conn_close | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  Frame = #{
            type => conn_close, 
            error_code => Conn_Error, 
            error_message => Message
           },

  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

%% 3 - item frames
validate_packet([Offset, App_Error, Stream_ID, rst_stream | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  Frame = #{
            type => rst_stream,
            stream_id => Stream_ID, 
            error_code => App_Error, 
            offset => Offset
           },

  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Token, Conn_ID, Seq_Num, new_conn_id | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  Frame = #{
            type => new_conn_id,
            conn_id => Conn_ID,
            token => Token,
            sequence => Seq_Num
           },

  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

%% Stream items either 1 item, 2 items, 3 items, or 4 items.
%% Either stream_data or stream_close type.
validate_packet([Message, Stream_ID, {stream_data, 0, _} | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  <<_:60, Type:1, Owner:1>> = <<Stream_ID:62>>,

  Frame = #{
            type => stream_open,
            stream_id => Stream_ID,
            offset => 0,
            stream_owner => Owner,
            stream_type => Type,
            data => Message
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Message, Stream_ID, {stream_close, 0, _} | Rest],
                Acc, Ack_Frames, TLS_Info) ->

  <<_:60, Type:1, Owner:1>> = <<Stream_ID:62>>,

  Frame = #{
            type => stream_close,
            stream_id => Stream_ID,
            offset => 0,
            stream_owner => Owner,
            stream_type => Type,
            data => Message
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);  

%% Offset set
validate_packet([Message, Offset, Stream_ID, {stream_data, 1, _} | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  <<_:60, Type:1, Owner:1>> = <<Stream_ID:62>>,

  Frame = #{
            type => stream_data,
            stream_id => Stream_ID,
            offset => Offset,
            stream_owner => Owner,
            stream_type => Type,
            data => Message
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

validate_packet([Message, Offset, Stream_ID, {stream_close, 1, _} | Rest], 
                Acc, Ack_Frames, TLS_Info) ->

  <<_:60, Type:1, Owner:1>> = <<Stream_ID:62>>,

  Frame = #{
            type => stream_close,
            stream_id => Stream_ID,
            offset => Offset,
            stream_owner => Owner,
            stream_type => Type,
            data => Message
           },
  validate_packet(Rest, [Frame | Acc], Ack_Frames, TLS_Info);

%% Ack block. This is the only one that keeps the reversed ordered.
%% Smallest to Largest makes more sense to process on the connection side.
%% Begins with end_ack_block atom and ends with ack_frame atom.
%% This does traverse the entire ack block frame twice, so it is a potential
%% source of optimization.
%% TODO: Update this to something better.
validate_packet([end_ack_block | Rest], Frames, Ack_Frames, TLS_Info) ->
  read_acks(Rest, Frames, Ack_Frames, TLS_Info, []);

validate_packet([end_ecn, ECN_CE, ECT1, ECT2 | Rest], Frames, Ack_Frames, TLS_Info) ->
  read_acks(Rest, Frames, Ack_Frames, TLS_Info, [{ecn_count, {ECT1, ECT2, ECN_CE}}]).


%% Pops all ack ranges off the stack and into a new accumulator to allow
%% in order processessing of the ack ranges.
read_acks([Ack_Block, _Block_Count, Delay, Largest_Ack, ack_frame | Stack], 
          Frames, Ack_Frames, TLS_Info, Acc) ->
  
  Ack_Frame = #{
                type => ack_frame,
                largest => Largest_Ack,
                ack_delay => Delay,
                acks => []
               },

  construct_ack_frame(Stack, Frames, Ack_Frames, 
                      TLS_Info, [Ack_Block | Acc], Ack_Frame, Largest_Ack);

read_acks([Ack_Block, Gap_Block | Rest], Frames, Ack_Frames, TLS_Info, Acc) ->
  read_acks(Rest, Frames, Ack_Frames, TLS_Info, [Gap_Block, Ack_Block | Acc]).

%% Calculates the largest and smallest ack packet number in the frame
%% Pushes it onto the ack_frame list.
construct_ack_frame(Stack, Frames, Ack_Frames, 
                    TLS_Info, [Ack], 
                    #{acks := Ack_List
                     } = Ack_Frame0, Prev_Largest) ->
  Smallest = Prev_Largest - Ack, 
  New_Ack_Range = lists:seq(Smallest, Prev_Largest),
  
  Ack_Frame = Ack_Frame0#{acks := [New_Ack_Range | Ack_List]},
  
  validate_packet(Stack, Frames, [Ack_Frame | Ack_Frames], TLS_Info);

construct_ack_frame(Stack, Frames, Ack_Frames, 
                    TLS_Info, [Ack, {ecn_count, ECN_Counts}], 
                    #{acks := Ack_List
                     } = Ack_Frame0, Prev_Largest) ->
  Smallest = Prev_Largest - Ack, 
  New_Ack_Range = lists:seq(Smallest, Prev_Largest),
  
  Ack_Frame = Ack_Frame0#{acks := [New_Ack_Range | Ack_List],
                          ecn_count => ECN_Counts},
  
  validate_packet(Stack, Frames, [Ack_Frame | Ack_Frames], TLS_Info);

%% The next largest ack is given by:
%% Next_Largest = Smallest - Gap - 2
%% where, 
%% Smallest = Largest - Ack
%% See Section 7.15.1
construct_ack_frame(Stack, Frames, Ack_Frames, 
                    TLS_Info, [Ack, Gap | Rest],
                    #{acks := Ack_List
                     } = Frame0, Prev_Largest) ->

  Smallest_Ack = Prev_Largest - Ack,
  New_Ack_Range = lists:seq(Smallest_Ack, Prev_Largest),

  Next_Largest = Smallest_Ack - Gap - 2,

  Ack_Frame = Frame0#{acks := [New_Ack_Range | Ack_List]},

  construct_ack_frame(Stack, Frames, TLS_Info, Ack_Frames, Rest, Ack_Frame, Next_Largest).


%% Not called anymore. Leaving for debug purposes.
%% parse_frames(<<Binary/bits>>, Packet_Info) ->
%%   parse_next(Binary, [], [parse_frame]).

parse_frame(<<>>, Stack) ->
  validate_packet(Stack);

parse_frame(<<0:1, 0:1, 0:1, 0:1, Type:4, Rest/bits>>, Stack) ->
  case Type of
    0 ->
      parse_next(Rest, Stack, padding());

    1 ->
      parse_next(Rest, [rst_stream | Stack], rst_stream());

    2 ->
      parse_next(Rest, [conn_close | Stack], conn_close());

    3 ->
      parse_next(Rest, [app_close | Stack], app_close());

    4 ->
      parse_next(Rest, [max_data | Stack], max_data());

    5 ->
      parse_next(Rest, [max_stream_data | Stack], max_stream_data());

    6 ->
      parse_next(Rest, [max_stream_id | Stack], max_stream_id());

    7 ->
      parse_next(Rest, [ping | Stack], ping());

    8 ->
      parse_next(Rest, [data_blocked | Stack], data_blocked());

    9 ->
      parse_next(Rest, [stream_data_blocked | Stack], stream_data_blocked());

    10 ->
      parse_next(Rest, [stream_id_blocked | Stack], stream_id_blocked());

    11 ->
      parse_next(Rest, [new_conn_id | Stack], new_conn_id());

    12 ->
      parse_next(Rest, [stop_sending | Stack], stop_sending());

    13 ->
      parse_next(Rest, [retire_conn_id | Stack], retire_conn_id());

    14 ->
      parse_next(Rest, [path_challenge | Stack], path_challenge());

    15 ->
      parse_next(Rest, [path_response | Stack], path_response())
  end;

parse_frame(<<24:8, Rest/bits>>, Stack) ->
  parse_next(Rest, [crypto_frame | Stack], crypto_frame());

parse_frame(<<26:8, Rest/bits>>, Stack) ->
  parse_next(Rest, [ack_frame | Stack], ack_frame());  

parse_frame(<<27:8, Rest/bits>>, Stack) ->
  parse_next(Rest, [ack_frame | Stack], ack_frame_ecn());

parse_frame(<<1:4, 0:1, Off:1, Len:1, 0:1 , Rest/bits>>, Stack) ->
  parse_next(Rest, 
             [{stream_data, Off, Len} | Stack], 
             stream({Off, Len}));

parse_frame(<<1:4, 0:1, Off:1, Len:1, 1:1 , Rest/bits>>, Stack) ->
  parse_next(Rest, 
             [{stream_close, Off, Len} | Stack], 
             stream({Off, Len}));

parse_frame(Other, _Stack) ->
  io:format("Unknown frame: ~p~n", [Other]),
  {error, badarg}.


parse_app_error(<<?STOPPING:16, Rest/binary>>, Stack, Funs) ->
  parse_next(Rest, [stopping | Stack], Funs);

parse_app_error(<<_App_Error:16, Rest/binary>>, Stack, Funs) ->
  parse_next(Rest, [app_error | Stack], Funs);

parse_app_error(_Other, _Stack, _Funs) ->
  {error, badarg}.


parse_conn_error(<<Type:16, Rest/bits>>, Stack, Funs) ->
  parse_next(Rest, [conn_error(Type) | Stack], Funs).


conn_error(?NO_ERROR) ->
  ok;
conn_error(?INTERNAL_ERROR) ->
  {error, internal};
conn_error(?SERVER_BUSY) ->
  {error, server_busy};
conn_error(?FLOW_CONTROL_ERROR) ->
  {error, flow_control};
conn_error(?STREAM_ID_ERROR) ->
  {error, stream_id};
conn_error(?STREAM_STATE_ERROR) ->
  {error, stream_state};
conn_error(?FINAL_OFFSET_ERROR) ->
  {error, final_offset};
conn_error(?FRAME_FORMAT_ERROR) ->
  {error, frame_format};
conn_error(?TRANSPORT_PARAMETER_ERROR) ->
  {error, transport_param};
conn_error(?VERSION_NEGOTIATION_ERROR) ->
  {error, version_neg_error};
conn_error(?PROTOCOL_VIOLATION) ->
  {error, protocol_violation};
conn_error(?UNSOLICITED_PATH_RESPONSE) ->
  {error, path_response};
conn_error(Frame_Error) when 
    Frame_Error >= 100, Frame_Error =< 123 ->
  {error, frame_error};
%% TODO: frame_error(Frame_Error)
conn_error(_Other) ->
  {error, badarg}.


parse_token(<<Token:128, Rest/bits>>, Stack, Funs) ->
  parse_next(Rest, [Token | Stack], Funs).


parse_ack_blocks(<<Binary/bits>>, [Count | _]=Stack, Funs) ->
  parse_ack_blocks(Binary, Stack, Funs, Count).


%% Parse one value for the final ack range.
parse_ack_blocks(<<Binary/bits>>, Stack, Funs, 0) ->
  parse_next(Binary, Stack, [parse_var_length, parse_var_length | Funs]);

%% Parse two values, one ack range and one gap range.
parse_ack_blocks(<<Binary/bits>>, Stack, Funs, Count) ->
  parse_ack_blocks(Binary, Stack, [parse_var_length, parse_var_length | Funs], Count-1).


parse_var_length(<<Offset:2, Rest/bits>>, Stack, Funs) ->
  parse_offset(Rest, Stack, Funs, Offset).

parse_offset(<<Integer:6, Rest/bits>>, Stack, Funs, 0) ->
  parse_next(Rest, [Integer | Stack], Funs);

parse_offset(<<Integer:14, Rest/bits>>,Stack, Funs, 1) ->
  parse_next(Rest, [Integer | Stack], Funs);

parse_offset(<<Integer:30, Rest/bits>>, Stack, Funs, 2) ->
  parse_next(Rest, [Integer | Stack], Funs);

parse_offset(<<Integer:62, Rest/bits>>, Stack, Funs, 3) ->
  parse_next(Rest, [Integer | Stack], Funs);

parse_offset(<<_Error/bits>>, _Stack, _Funs, _Offset) ->
  io:format("Error, bad offset.~n"),
  {error, badarg}.


%% This is only used for the new connection id frame.
parse_conn_len(<<_:3, Integer:5, Rest/bits>>, Stack, Funs) ->
  parse_next(Rest, [Integer | Stack], Funs).


parse_conn_id(<<Binary/bits>>, [_, Length | _] = Stack, Funs) ->
  parse_conn_id(Binary, Stack, Funs, Length, <<>>).

parse_conn_id(<<Binary/bits>>, Stack, Funs, 0, Conn_ID) ->
  parse_next(Binary, [Conn_ID | Stack], Funs);

parse_conn_id(<<Part:1/binary, Rest/bits>>, Stack, Funs, Len, Conn) ->
  parse_conn_id(Rest, Stack, Funs, Len-1, <<Conn/binary, Part/binary>>).

%% This is to allow for the sub-binary creation to be delayed.
parse_message(<<Offset:2, Rest/bits>>, Stack, Funs) ->  
  parse_offset_message(Rest, Stack, Funs, Offset).

parse_message(<<Binary/bits>>, Stack, Funs, Length) ->
  <<Message:Length/binary, Rest/bits>> = Binary,
  parse_next(Rest, [<<Message/binary>>, Length | Stack], Funs).

parse_offset_message(<<Integer:6, Rest/bits>>, Stack, Funs, 0) ->
  parse_message(Rest, Stack, Funs, Integer);

parse_offset_message(<<Integer:14, Rest/bits>>,Stack, Funs, 1) ->
  parse_message(Rest, Stack, Funs, Integer);

parse_offset_message(<<Integer:30, Rest/bits>>, Stack, Funs, 2) ->
  parse_message(Rest, Stack, Funs, Integer);

parse_offset_message(<<Integer:62, Rest/bits>>, Stack, Funs, 3) ->
  parse_message(Rest, Stack, Funs, Integer);

parse_offset_message(<<_Error/bits>>, _Stack, _Funs, _Offset) ->
  io:format("Error, bad message.~n"),
  {error, badarg}.



