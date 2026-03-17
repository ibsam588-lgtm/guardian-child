import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/pairing_service.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final List<TextEditingController> _controllers =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focuses = List.generate(6, (_) => FocusNode());

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers) c.dispose();
    for (final f in _focuses) f.dispose();
    super.dispose();
  }

  String get _code => _controllers.map((c) => c.text).join();

  void _onDigitChanged(int index, String value) {
    if (value.isEmpty) {
      if (index > 0) _focuses[index - 1].requestFocus();
    } else {
      if (index < 5) {
        _focuses[index + 1].requestFocus();
      } else {
        _focuses[index].unfocus();
        if (_code.length == 6) _submitCode();
      }
    }
  }

  Future<void> _submitCode() async {
    if (_code.length < 6) {
      setState(() => _error = 'Please enter all 6 digits');
      return;
    }
    setState(() { _loading = true; _error = null; });

    final pairing = context.read<PairingService>();
    final result = await pairing.pairWithCode(_code);

    if (!mounted) return;
    setState(() => _loading = false);

    if (result == PairingResult.success) {
      // Start monitor only after permissions are granted (handled in permissions screen)
      context.go('/permissions');
    } else {
      setState(() => _error = result.message);
      // Clear fields on error
      for (final c in _controllers) c.clear();
      _focuses[0].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 60),
              // Icon
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.primary, AppTheme.secondary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.link_rounded, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 28),
              const Text(
                'Connect to Parent',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Color(0xFF2D2D2D)),
              ),
              const SizedBox(height: 10),
              Text(
                'Ask your parent to open GuardIan\nand share the 6-digit code with you.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey[600], height: 1.5),
              ),
              const SizedBox(height: 48),

              // 6-digit input
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (i) {
                  return _DigitBox(
                    controller: _controllers[i],
                    focusNode: _focuses[i],
                    onChanged: (v) => _onDigitChanged(i, v),
                    onBackspace: () {
                      if (_controllers[i].text.isEmpty && i > 0) {
                        _focuses[i - 1].requestFocus();
                        _controllers[i - 1].clear();
                      }
                    },
                  );
                }),
              ),

              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.secondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, color: AppTheme.secondary, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(_error!, style: TextStyle(color: AppTheme.secondary, fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submitCode,
                  child: _loading
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                        )
                      : const Text('Connect'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DigitBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onBackspace;

  const _DigitBox({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 56,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focusNode.hasFocus ? AppTheme.primary : const Color(0xFFE0E0E0),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: (e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.backspace) {
            onBackspace();
          }
        },
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          maxLength: 1,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFF2D2D2D)),
          decoration: const InputDecoration(
            counterText: '',
            border: InputBorder.none,
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
