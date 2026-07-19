import 'package:flutter/material.dart';

class SocialMediaScannerScreen extends StatefulWidget {
  @override
  _SocialMediaScannerScreenState createState() =>
      _SocialMediaScannerScreenState();
}

class _SocialMediaScannerScreenState extends State<SocialMediaScannerScreen> {
  final TextEditingController _handleController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  bool _autoScanEnabled = false;
  bool _pushNotificationsEnabled = true;

  @override
  void dispose() {
    _handleController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _startScan() {
    if (_handleController.text.isEmpty || _emailController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please fill in both handle and email'),
          backgroundColor: Colors.red[600],
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Privacy report will be sent to ${_emailController.text}'),
        backgroundColor: Colors.green[600],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Color(0xFF0C7FF2);
    final slate100 = Color(0xFFF1F5F9);
    final slate200 = Color(0xFFE2E8F0);
    final slate300 = Color(0xFFCBD5E1);
    final slate400 = Color(0xFF94A3B8);
    final slate500 = Color(0xFF64748B);
    final slate600 = Color(0xFF475569);
    final slate700 = Color(0xFF334155);
    final slate800 = Color(0xFF1E293B);
    final slate900 = Color(0xFF0F172A);

    return Scaffold(
      backgroundColor: slate100,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: slate700),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Social Media Scanner',
          style: TextStyle(
            color: slate900,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Wrap the main content in Expanded and SingleChildScrollView
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.security,
                          size: 48,
                          color: primaryColor,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Get Your Detailed Privacy Report',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: slate900,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Enter your social media handle and email to receive insights into your online privacy.',
                          style: TextStyle(
                            fontSize: 16,
                            color: slate600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 32),
                  Text(
                    'Account Details',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: slate900,
                    ),
                  ),
                  SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: slate300),
                    ),
                    child: Row(
                      children: [
                        Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.alternate_email, color: slate400),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _handleController,
                            decoration: InputDecoration(
                              hintText: '@username',
                              border: InputBorder.none,
                              contentPadding:
                                  EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: slate300),
                    ),
                    child: Row(
                      children: [
                        Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.email_outlined, color: slate400),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              hintText: 'you@example.com',
                              border: InputBorder.none,
                              contentPadding:
                                  EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 32),
                  Text(
                    'Scan Settings',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: slate900,
                    ),
                  ),
                  SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: slate200),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ListTile(
                      title: Text(
                        'Automatic Scans',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: slate800,
                        ),
                      ),
                      subtitle: Text(
                        'Scan your account every 30 days',
                        style: TextStyle(
                          color: slate500,
                        ),
                      ),
                      trailing: Switch(
                        value: _autoScanEnabled,
                        onChanged: (value) {
                          setState(() {
                            _autoScanEnabled = value;
                          });
                        },
                        activeColor: primaryColor,
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: slate200),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ListTile(
                      title: Text(
                        'Push Notifications',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: slate800,
                        ),
                      ),
                      subtitle: Text(
                        'Get notified of risk status changes',
                        style: TextStyle(
                          color: slate500,
                        ),
                      ),
                      trailing: Switch(
                        value: _pushNotificationsEnabled,
                        onChanged: (value) {
                          setState(() {
                            _pushNotificationsEnabled = value;
                          });
                        },
                        activeColor: primaryColor,
                      ),
                    ),
                  ),
                  // Add some bottom padding to ensure content doesn't get cut off
                  SizedBox(height: 24),
                ],
              ),
            ),
          ),
          // Keep the button at the bottom
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              border: Border(
                top: BorderSide(
                  color: slate200,
                  width: 1,
                ),
              ),
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _startScan,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: Text(
                    'Get Report',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
