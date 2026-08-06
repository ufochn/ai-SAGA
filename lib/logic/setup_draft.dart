import 'storage_service.dart';

/// 初始化设定草稿（仅存于内存，不持久化）。
///
/// 设置流程中各页（地点、年代、主角、搭档）的选择，在用户于最终确认页
/// 点击"确定"并完成倒计时（进入正式主页面）之前，仅写入此处；
/// 确认时才通过 [commit] 统一写入 [StorageService] 完成持久化，
/// 并标记 [StorageService.setInitialized]。
///
/// 说明：语言（language）不在此草稿内——语言属于应用界面语言，已在
/// 轻授权门卫（LanguageFirstGate）前选择并持久化，设置流程沿用该值。
class SetupDraft {
  SetupDraft._();
  static final SetupDraft instance = SetupDraft._();

  String location = '';
  String era = '';
  String playerName = '';
  String playerGender = '';
  String partnerName = '';
  String partnerGender = '';
  String partnerTraits = '';

  /// 清空所有草稿值
  void reset() {
    location = '';
    era = '';
    playerName = '';
    playerGender = '';
    partnerName = '';
    partnerGender = '';
    partnerTraits = '';
  }

  /// 将全部草稿值写入持久化存储，并标记为已初始化。
  Future<void> commit() async {
    await StorageService.saveLocation(location);
    await StorageService.saveEra(era);
    await StorageService.savePlayerName(playerName);
    await StorageService.savePlayerGender(playerGender);
    await StorageService.savePartnerName(partnerName);
    await StorageService.savePartnerGender(partnerGender);
    await StorageService.savePartnerTraits(partnerTraits);
    await StorageService.setInitialized();
  }
}
