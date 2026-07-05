import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Reproduces the original app's local-only privacy policy.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <List<String>>[
    [
      '1. Introduction',
      'This Privacy Policy explains our approach to data handling in the Url '
          'Video Player application. We are committed to protecting your privacy '
          'and ensuring transparency about how your data is handled.'
    ],
    [
      '2. No Personal Data Collection',
      'We want to explicitly state that this application DOES NOT collect any '
          'personal data. We do not gather, store, or transmit any personally '
          'identifiable information to external servers.'
    ],
    [
      '3. Local Data Storage Only',
      'Any data generated while using this app (such as video URLs, playback '
          'history, and favorites) is stored exclusively on your device. This '
          'data never leaves your device and is not accessible to us or any '
          'third parties.'
    ],
    [
      '4. Data You Provide',
      'The app only stores information that you explicitly provide, such as '
          'video URLs you enter and your viewing history. This information is '
          'stored locally on your device for your convenience.'
    ],
    [
      '5. Data Access and Control',
      'Since all data is stored locally on your device, you have complete '
          'control over it. You can delete your history and favorites at any '
          'time through the app interface.'
    ],
    [
      '6. Internet Permission',
      'The app requires internet permission solely to stream videos from the '
          'URLs you provide. This permission is not used to send any of your '
          'data to external servers.'
    ],
    [
      '7. Third-Party Links',
      'Our app may contain links to third-party websites or services. We are '
          'not responsible for the privacy practices or content of these '
          'third-party sites.'
    ],
    [
      '8. Changes to Privacy Policy',
      'We may update this Privacy Policy from time to time. We will notify you '
          'of any changes by posting the new Privacy Policy in the app.'
    ],
    [
      '9. Contact Us',
      'If you have any questions about this Privacy Policy, please contact us.'
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: AppTheme.primaryRed,
        title: const Text('Privacy Policy'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Version: 406',
              style: TextStyle(color: Colors.black54, fontSize: 15)),
          const SizedBox(height: 12),
          const Text('Last updated: December 2025',
              style: TextStyle(color: Colors.black54, fontSize: 15)),
          const SizedBox(height: 24),
          for (final s in _sections) ...[
            Text(
              s[0],
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87),
            ),
            const SizedBox(height: 6),
            Text(
              s[1],
              style: const TextStyle(
                  fontSize: 15, height: 1.4, color: Colors.black54),
            ),
            const SizedBox(height: 22),
          ],
        ],
      ),
    );
  }
}
