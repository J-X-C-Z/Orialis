part of 'sync_engine.dart';

extension SyncStatePresentation on SyncState {
  String get label => switch (this) {
    SyncState.idle => '已同步',
    SyncState.syncing => '同步中',
    SyncState.offline => '等待联网',
    SyncState.authRequired => '需要登录',
    SyncState.conflict => '需要处理',
    SyncState.error => '同步失败',
  };

  String get message => switch (this) {
    SyncState.idle => '本地内容已与服务器保持一致。',
    SyncState.syncing => '正在上传本地修改并获取最新内容。',
    SyncState.offline => '当前无法连接服务器，本地修改会继续保留。',
    SyncState.authRequired => '登录状态已失效，请重新登录后再同步；本地修改仍然保留。',
    SyncState.conflict => '发现版本冲突，本地修改已保留，不会被静默覆盖。',
    SyncState.error => '同步没有完成，请稍后重试；本地修改仍然保留。',
  };
}
