import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rtc_demo/rtc_signaling.dart';
import 'package:flutter_webrtc/rtc_video_view.dart';

class P2PDemo extends StatefulWidget {
  // 远程信令服务器的url
  final String url;

  P2PDemo({Key key, @required this.url}) : super(key: key);

  @override
  _P2PDemoState createState() => _P2PDemoState(serverurl: url);
}

class _P2PDemoState extends State<P2PDemo> {
  // 信令服务器地址
  final String serverurl;

  _P2PDemoState({Key key, @required this.serverurl});

  // rtc 信令对象
  RTCSignaling _rtcSignaling;

  // 本地设备名称 传递给信令服务器 用于当房间的名称
  String _displayName =
      '${Platform.localeName.substring(0, 2)} + ( ${Platform.operatingSystem} )';
      
  // 房间内的成员 由后端传入 点对点时 应该可以不使用
  List<dynamic> _peers;
  // 自己的id
  var _selfId;
  // 本地媒体视频窗口
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  // 对端媒体视频窗口
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  // 是否通话中
  bool _inCalling = false;

  // 初始化
  @override
  void initState() {
    super.initState();
    // 初始化渲染窗口
    initRenderers();
    // 连接服务器的WebSocket 并不会创建PeerConnection 只有在邀请对方时 才会创建
    _connect();
  }

  // 懒加载本地和对端渲染窗口
  initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  // 销毁操作 widget销毁时 将远程和本地的渲染也销毁
  @override
  void deactivate() {
    super.deactivate();
    if (_rtcSignaling != null) _rtcSignaling.close();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
  }

  // 创建联系
  void _connect() async {
    // 初始化信令
    if (_rtcSignaling == null) {
      // 信令不存在 则创建 url为后端node服务器 displayName为设备名称并传递给信令服务器 再传递回来作为房间名
      _rtcSignaling = RTCSignaling(url: serverurl, displayName: _displayName);
      // 信令状态改变
      // 放在这里的原因是因为 有些变量是在这个文件的 可以尝试将这些变量转移到rtc_signaling文件 再进行初始化这个函数 应该是可以的
      _rtcSignaling.onStateChange = (SignalingState state) {
        // 根据不同的状态进行不同的操作
        switch (state) {
          // 创建时
          case SignalingState.CallStateNew:
            setState(() {
              _inCalling = true;
            });
            break;
          // 离开时 清除本地和远程的媒体 并设置isCalling为false 即未在通话
          case SignalingState.CallStateBye:
            setState(() {
              _localRenderer.srcObject = null;
              _remoteRenderer.srcObject = null;
              _inCalling = false;
            });
            break;
          case SignalingState.CallStateRinging:
            break;
          case SignalingState.CallStateInvite:
            break;
          case SignalingState.CallStateConnected:
            break;

          case SignalingState.ConnectionOpen:
            break;
          case SignalingState.ConnectionClosed:
            break;
          case SignalingState.ConnectionError:
            break;
        }
      };
      // 更新房间人员列表 从服务器接收到新的人员列表 进行赋值
      _rtcSignaling.onPeersUpdate = ((event) {
        setState(() {
          _selfId = event['self'];
          _peers = event['peers'];
        });
      });

      // 设置本地媒体 将本地媒体设置给本地渲染器
      _rtcSignaling.onLocalStream = ((stream) {
        _localRenderer.srcObject = stream;
      });

      // 设置远端媒体 将远端媒体设置给远程渲染器
      _rtcSignaling.onAddRemoteStream = ((stream) {
        _remoteRenderer.srcObject = stream;
      });

      // 移除远端媒体 清除远程渲染器
      _rtcSignaling.onRemoveRemoteStream = ((stream) {
        _remoteRenderer.srcObject = null;
      });

      // 发送socket请求 并进行注册 不会创建PeerConnection连接
      _rtcSignaling.connect();
    }
  }

  // 邀请对方
  _invitePeer(peerId) async {
    if (_rtcSignaling != null && peerId != _selfId) {
      // 这里才会创建PC连接
      _rtcSignaling.invite(peerId);
    }
  }
  
  // 挂断
  _hangUp() {
    if (_rtcSignaling != null) {
      _rtcSignaling.bye();
    }
  }
  // 切换前后摄像头
  _switchCamera() {
    _rtcSignaling.switchCamera();
    _localRenderer.mirror = true;
  }
  // 初始化 列表
  _buildRow(context, peer) {
    bool self = (peer['id'] == _selfId);

    return ListBody(
      children: <Widget>[
        ListTile(
          title: Text(self
              ? 'self is $_selfId'
              : 'him is ${peer['id']}'),
          trailing: SizedBox(
            width: 100.0,
            child: IconButton(
              icon: Icon(Icons.videocam),
              onPressed: () => _invitePeer(peer['id']),
            ),
          ),
        ),
        Divider()
      ],
    );
  }

  // 构建当前视图
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('P2P Call sample'),
        leading: BackButton(),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _inCalling
          ? SizedBox(
              width: 200.0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  FloatingActionButton(
                    heroTag: 1,
                    onPressed: _switchCamera,
                    child: Icon(Icons.switch_camera),
                  ),
                  FloatingActionButton(
                    heroTag: 2,
                    onPressed: _hangUp,
                    child: Icon(Icons.call_end),
                    backgroundColor: Colors.deepOrange,
                  )
                ],
              ),
            )
          : null,
      body: _inCalling
          ? OrientationBuilder(
              builder: (context, orientation) {
                return Container(
                  child: Stack(
                    children: <Widget>[
                      Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            margin: EdgeInsets.all(0),
                            width: MediaQuery.of(context).size.width,
                            height: MediaQuery.of(context).size.height,
                            child: RTCVideoView(_remoteRenderer),
                            decoration: BoxDecoration(color: Colors.grey),
                          )),
                      Positioned(
                          right: 20.0,
                          top: 20.0,
                          child: Container(
                            width: orientation == Orientation.portrait
                                ? 90.0
                                : 120.0,
                            height: orientation == Orientation.portrait
                                ? 120.0
                                : 90.0,
                            child: RTCVideoView(_localRenderer),
                            decoration: BoxDecoration(color: Colors.black54),
                          ))
                    ],
                  ),
                );
              },
            )
          : ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.all(0.0),
              itemCount: (_peers != null ? _peers.length : 0),
              itemBuilder: (context, i) {
                return _buildRow(context, _peers[i]);
              }),
    );
  }
}
