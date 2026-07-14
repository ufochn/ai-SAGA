import 'package:flutter/material.dart';
import 'package:flutter_application_1/logic/storage_service.dart';

/// 游戏初始化页面 - 角色设定
/// 当主文本为空时自动显示
class InitializationPage extends StatefulWidget {
  final VoidCallback onComplete;

  const InitializationPage({super.key, required this.onComplete});

  @override
  State<InitializationPage> createState() => _InitializationPageState();
}

class _InitializationPageState extends State<InitializationPage> {
  final TextEditingController _playerNameController = TextEditingController();
  final TextEditingController _partnerNameController = TextEditingController();
  final TextEditingController _partnerTraitsController =
      TextEditingController();
  String _playerGender = '男';
  String _partnerGender = '女';

  @override
  void dispose() {
    _playerNameController.dispose();
    _partnerNameController.dispose();
    _partnerTraitsController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    StorageService.savePlayerName(_playerNameController.text);
    StorageService.savePlayerGender(_playerGender);
    StorageService.savePartnerName(_partnerNameController.text);
    StorageService.savePartnerGender(_partnerGender);
    StorageService.savePartnerTraits(_partnerTraitsController.text);
    StorageService.setInitialized();
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: MediaQuery.of(context).size.width * 0.05,
        vertical: 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '欢迎您进入这个冒险探案恋爱游戏。',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            '在游戏开始前，请您先做一些小小的设定。',
            style: TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          // 玩家姓名
          const Text('您在游戏中的姓名：', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            controller: _playerNameController,
            decoration: const InputDecoration(
              hintText: '请输入姓名',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 玩家性别
          const Text('您的性别：', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _playerGender,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            items: const [
              DropdownMenuItem(value: '男', child: Text('男')),
              DropdownMenuItem(value: '女', child: Text('女')),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _playerGender = value;
                });
              }
            },
          ),
          const SizedBox(height: 20),
          // 搭档姓名
          const Text('您的搭档及暧昧对象姓名：', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            controller: _partnerNameController,
            decoration: const InputDecoration(
              hintText: '请输入姓名',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 搭档性别
          const Text('他（她）的性别：', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _partnerGender,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            items: const [
              DropdownMenuItem(value: '男', child: Text('男')),
              DropdownMenuItem(value: '女', child: Text('女')),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _partnerGender = value;
                });
              }
            },
          ),
          const SizedBox(height: 20),
          // 搭档特质
          const Text(
            '他（她）的任何个人特质，性格、外貌，喜好等等，请随意输入。',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _partnerTraitsController,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: '不输入则系统随机生成',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 32),
          // 确认按钮
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _onSubmit,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('确认设定', style: TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
