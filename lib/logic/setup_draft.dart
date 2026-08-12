/// 初始化设定草稿（仅存于内存，不持久化）。
///
/// 设置流程中各页（地点、年代、主角、搭档）的选择，在用户于最终确认页
/// 点击"确定"并完成倒计时（进入正式主页面）之前，仅写入此处；
/// 首篇生成时这些设定随请求一并发给服务器落库（story_segments 设定快照列），
/// 本地不持久化。
///
/// 说明：语言（language）不在此草稿内——语言属于应用界面语言，已在
/// 启动阶段选定/回退系统语言并持久化，设置流程沿用该值。
class SetupDraft {
  SetupDraft._();
  static final SetupDraft instance = SetupDraft._();

  String location = '';
  String era = '';
  String playerName = '';
  String playerGender = '';
  String playerTraits = '';
  String partnerName = '';
  String partnerGender = '';
  String partnerTraits = '';

  /// 清空所有草稿值
  void reset() {
    location = '';
    era = '';
    playerName = '';
    playerGender = '';
    playerTraits = '';
    partnerName = '';
    partnerGender = '';
    partnerTraits = '';
  }
}
