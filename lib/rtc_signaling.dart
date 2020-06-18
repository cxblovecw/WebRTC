import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/webrtc.dart';

import 'package:web_socket_channel/io.dart';

import 'package:random_string/random_string.dart';

// 信令状态
enum SignalingState {
  CallStateNew,
  CallStateRinging,
  CallStateInvite,
  CallStateConnected,
  CallStateBye,
  ConnectionOpen,
  ConnectionClosed,
  ConnectionError,
}

/*
 * callbacks for Signaling API.
 */

// 信令状态的回调
typedef SignalingStateCallback(SignalingState state);
// 媒体流的状态回调
typedef StreamStateCallback(MediaStream stream);
// 对方进入房价回调
typedef OtherEventCallback(dynamic event);


class RTCSignaling {
  final String _selfId = randomNumeric(6);
  // 用于接收客户端的WebSocket的数据
  IOWebSocketChannel _channel;
  // SessionID
  String _sessionId;

  String url;
  String displayName;
  // 用于存储peerConnection对象 注意点是 这里的key是对方的id value存的是自己的RTCPeerConnection对象
  var _peerConnections = new Map<String, RTCPeerConnection>();

  MediaStream _localStream;
  List<MediaStream> _remoteStreams;
  JsonDecoder decoder = new JsonDecoder();
  
  SignalingStateCallback onStateChange;
  
  StreamStateCallback onLocalStream;
  StreamStateCallback onAddRemoteStream;
  StreamStateCallback onRemoveRemoteStream;
  OtherEventCallback onPeersUpdate;
  

  /*
  * ice turn、stun 服务器 配置
  * */
  Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'url': 'stun:stun.l.google.com:19302'},
      /*
       * turn server configuration example.
      {
        'url': 'turn:123.45.67.89:3478',
        'username': 'change_to_real_user',
        'credential': 'change_to_real_secret'
      },
       */
    ]
  };

  /*
  * DTLS 是否开启
  * */
  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ],
  };

  /*
  *  offer和answer所需要的限制
  * */
  final Map<String, dynamic> _constraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
    'optional': [],
  };

  RTCSignaling({this.url, this.displayName});

  /*
  * socket 连接
  * */
  void connect() async {
    try {
      // 创建 channel  用于发送WebSocket请求
      _channel = IOWebSocketChannel.connect(url);

      print('连接成功');
      // 调用方法 并传递参数  该方法在p2p中已经复制了 通过switch进行判断
      this.onStateChange(SignalingState.ConnectionOpen);

      // 接收服务器发送的消息
      _channel.stream.listen((message) {
        print('receive $message');
        // 自定义的消息处理函数
        onMessage(message);
      }).onDone(() {
        // 当stream关闭以后触发
        print('Closed by server!');

        // if (this.onStateChange != null) {
        //   this.onStateChange(SignalingState.ConnectionClosed);
        // }
      });

      /*
      * 连接socket注册
      * */
      _send('new', {
        'name': displayName,  // 用于后续返回 作为房间名
        'id': _selfId,        // 每个人的专属id 随机的6位数
        // 'user_agent': 'flutter-webrtc + ${Platform.operatingSystem}' // 好像没啥用
      });
    } catch (e) {
      print(e.toString());
      if (this.onStateChange != null) {
        this.onStateChange(SignalingState.ConnectionError);
      }
    }
  }

  /*
  * 创建本地媒体流
  * */
  Future<MediaStream> createStream() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': {
        'mandatory': {
          'minWidth':
              '640', // Provide your own width, height and frame rate here
          'minHeight': '480',
          'minFrameRate': '30',
        },
        'facingMode': 'user',
        'optional': [],
      }
    };
    // 1.呼叫者通过navigator.getUserMedia获取本地媒体
    MediaStream stream = await navigator.getUserMedia(mediaConstraints);
    // 此处是this代表的是RTCSignaling的实例对象
    if (this.onLocalStream != null) {
      this.onLocalStream(stream);
    }
    return stream;
  }

  /*
  * 关闭本地媒体，断开socket
  * */
  close() {
    if (_localStream != null) {
      _localStream.dispose();
      _localStream = null;
    }

    _peerConnections.forEach((key, pc) {
      pc.close();
    });

    if (_channel != null) _channel.sink.close();
  }

  /*
  * 切换前后摄像头
  * */
  void switchCamera() {
    if (_localStream != null) {
      _localStream.getVideoTracks()[0].switchCamera();
    }
  }

  /*
  * 邀请对方进行会话
  * */
  void invite(String peer_id) {
    // this._sessionId = '$_selfId-$peer_id}';
    // print("_sessionId"+this._sessionId.toString());

    if (this.onStateChange != null) {
      // 会将isCalling设置为true 在p2p文件中
      this.onStateChange(SignalingState.CallStateNew);
    }

    /*
    * 创建一个peerconnection  peer_id为对方的id 用户发送候选人的
    * */
    _createPeerConnection(peer_id).then((pc) {
      // 设置 _peerConnections对象 
      _peerConnections[peer_id] = pc;
      // 创建offer
      _createOffer(peer_id, pc);
    });
  }

  /*
  * 收到消息处理逻辑
  * */
  void onMessage(message) async {
    // 将服务器发送过来的JSON字符串转换成Map对象
    Map<String, dynamic> mapData = decoder.convert(message);

    var data = mapData['data'];
    // 根据type的不同进行不同的操作
    switch (mapData['type']) {
      /*
      * 新成员加入刷新界面
      * */
      case 'peers':
        {
          List<dynamic> peers = data;
          if (this.onPeersUpdate != null) {
            Map<String, dynamic> event = Map<String, dynamic>();
            event['self'] = _selfId;
            event['peers'] = peers;
            this.onPeersUpdate(event);
          }
        }
        break;

      /*
      *  接收方 获取远程的offer
      * */
      case 'offer':
        {
          // 获取发送方的id
          String id = data['from'];
          // 获取发送方的描述
          var description = data['description'];
          // 获取会话id (说不定可以去掉)
          var sessionId = data['session_id'];
          this._sessionId = sessionId;

          if (this.onStateChange != null) {
            this.onStateChange(SignalingState.CallStateNew);
          }
          /*
          * 收到远端offer后 创建本地的peerconnection
          * 之后设置远端的媒体信息,并向对端发送answer进行应答
          * */
          // 这里的id是对方的id 用于发送候选人以及设置 _peerConnections 
          _createPeerConnection(id).then((pc) {
            // 这里的pc是自己的pc id是对方的id
            _peerConnections[id] = pc;
            // 将获取到的对方的描述信息复制给远程描述
            pc.setRemoteDescription(
                RTCSessionDescription(description['sdp'], description['type']));
            // 创建answer
            _createAnswer(id, pc);
          });
        }
        break;

      /*
      * 收到对端 answer
      * */
      case 'answer':
        {
          // 获取接收方的id
          String id = data['from'];
          // 接收方的描述信息
          Map description = data['description'];
          
          RTCPeerConnection pc = _peerConnections[id];
          if (pc != null) {
            // 给peerconnection设置远程描述信息
            pc.setRemoteDescription(
              RTCSessionDescription(description['sdp'], description['type']));
          }
        }
        break;
      /*
      * 客户端在创建PeerConnection时 会想信令服务器发送候选者
      * 收到远端的候选者，并添加给候选者
      * */
      case 'candidate':
      {
          // 对方的id
          String id = data['from'];
          // 获取候选者信息
          Map candidateMap = data['candidate'];

          RTCPeerConnection pc = _peerConnections[id];
          if (pc != null) {
            // 创建候选者对象
            RTCIceCandidate candidate = new RTCIceCandidate(
                candidateMap['candidate'],
                candidateMap['sdpMid'],
                candidateMap['sdpMLineIndex']);
            // 给PeerConnection添加候选者
            pc.addCandidate(candidate);
          }
        }
        break;

      /*
      * 对方离开，断开连接
      * */
      // case 'leave':
      //   {
      //     // 对方的id
      //     var id = data;
      //     // 删除id对应的peerConnection
      //     _peerConnections.remove(id);
      //     if (_localStream != null) {
      //       // 删除本地的流对象
      //       _localStream.dispose();
      //       _localStream = null;
      //     }

      //     RTCPeerConnection pc = _peerConnections[id];
      //     if (pc != null) {
      //       pc.close();
      //       _peerConnections.remove(id);
      //     }
      //     print("pc是否存在:"+(pc!=null).toString());
      //     this._sessionId = null;
      //     if (this.onStateChange != null) {
      //       this.onStateChange(SignalingState.CallStateBye);
      //     }
      //   }
      //   break;

      case 'bye':
        {
          // 
          var to = data['to'];

          if (_localStream != null) {
            _localStream.dispose();
            _localStream = null;
          }

          RTCPeerConnection pc = _peerConnections[to];
          if (pc != null) {
            pc.close();
            _peerConnections.remove(to);
          }

          this._sessionId = null;
          if (this.onStateChange != null) {
            this.onStateChange(SignalingState.CallStateBye);
          }
        }
        break;

      case 'keepalive':
        {
          print('keepaive');
        }
        break;
    }
  }

  /*
  * 结束会话
  * */
  void bye() {
    _send('bye', {
      'session_id': this._sessionId,
      'from': this._selfId,
    });
  }

  /*
  * 创建peerconnection
  * */
  Future<RTCPeerConnection> _createPeerConnection(id) async {
    // 获取本地媒体
    _localStream = await createStream();
    // 2. 创建RTCPeerConnection
    RTCPeerConnection pc = await createPeerConnection(_iceServers, _config);
    // 3.将本地媒体流添加到链接上
    pc.addStream(_localStream);


    // pc.xxx 是PeerConnection自带的方法 方法是我们自定义的 但是方法已经被定义死了 参数是固定的 执行的时间也是他设置好的
    /*
    * 获得获选者 这个方法是PeerConnection自带的方法
    * */
    pc.onIceCandidate = (candidate) {
      // print(candidate);
      // print("SessionID是"+this._sessionId);
      /*
      * 获取候选者后，向对方发送候选者
      * */
      _send('candidate', {
        'to': id,
        'candidate': {
          'sdpMLineIndex': candidate.sdpMlineIndex,
          'sdpMid': candidate.sdpMid,
          'candidate': candidate.candidate,
        },
        'session_id': this._sessionId,
      });
    };

    // pc.onIceConnectionState = (state) {};

    /*
    * 获取远端的媒体流时触发的函数 这个方法是PeerConnection自带的方法
    * */
    pc.onAddStream = (stream) {
      if (this.onAddRemoteStream != null) this.onAddRemoteStream(stream);
    };


    /*
    * 移除远端的媒体流时触发的函数 
    * */
    pc.onRemoveStream = (stream) {
      if (this.onRemoveRemoteStream != null) this.onRemoveRemoteStream(stream);
      _remoteStreams.removeWhere((it) {
        return (it.id == stream.id);
      });
    };

    return pc;
  }

  /*
  * 创建offer
  * */
  _createOffer(String id, RTCPeerConnection pc) async {
    try {
      // 使用pc.createOffer(offerConstraints)方法 创建RTC会话描述 
      RTCSessionDescription s = await pc.createOffer(_constraints);
      // 设置本地描述
      pc.setLocalDescription(s);  
      //向远端发送自己的媒体信息
      _send('offer', {
        'to': id,
        'description': {'sdp': s.sdp, 'type': s.type},
        'session_id': this._sessionId,
      });
    } catch (e) {
      print(e.toString());
    }
  }

  /*
  * 创建answer
  * */
  _createAnswer(String id, RTCPeerConnection pc) async {
    try {
      RTCSessionDescription s = await pc.createAnswer(_constraints);
      pc.setLocalDescription(s);
      /*
      * 回复answer
      * */
      _send('answer', {
        'to': id,
        'description': {'sdp': s.sdp, 'type': s.type},
        'session_id': this._sessionId,
      });
    } catch (e) {
      print(e.toString());
    }
  }

  /*
  * 消息发送
  * */
  void _send(event, data) {
    data['type'] = event;
    JsonEncoder encoder = new JsonEncoder();
    if (_channel != null) _channel.sink.add(encoder.convert(data));
    print('send: ' + encoder.convert(data));
  }
}
