import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'scan_analysis_screen.dart';

class GalleryScreen extends StatefulWidget {
  @override
  _GalleryScreenState createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen>
    with TickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  final FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  final String _keyStorageName = 'gallery_aes_key';
  final String _textPostsFileName = 'text_posts_encrypted.dat';
  encrypt.Key? _aesKey;
  bool _isLoading = true;
  bool _showAddOptions = false;
  late AnimationController _fabAnimationController;
  late Animation<double> _fabAnimation;
  final TextEditingController _searchController = TextEditingController();
  bool _sortAscending = true;
  List<Map<String, dynamic>> _displayItems = [];

  List<Map<String, dynamic>> _mediaItems = [];

  @override
  void initState() {
    super.initState();
    _fabAnimationController = AnimationController(
      duration: Duration(milliseconds: 300),
      vsync: this,
    );
    _fabAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fabAnimationController, curve: Curves.easeInOut),
    );
    _initializeApp();
  }

  @override
  void dispose() {
    _fabAnimationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    try {
      await _initEncryptionKey();
      await _loadAllData();
      // initialize display items
      _refreshDisplayItems();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error initializing app: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _refreshDisplayItems() {
    final query = _searchController.text.trim().toLowerCase();
    List<Map<String, dynamic>> items = List.from(_mediaItems);

    if (query.isNotEmpty) {
      items = items.where((it) {
        final caption = (it['caption'] ?? '').toString().toLowerCase();
        final title = (it['title'] ?? '').toString().toLowerCase();
        return caption.contains(query) || title.contains(query);
      }).toList();
    }

    items.sort((a, b) {
      final aKey = (a['caption'] ?? a['title'] ?? '').toString().toLowerCase();
      final bKey = (b['caption'] ?? b['title'] ?? '').toString().toLowerCase();
      return _sortAscending ? aKey.compareTo(bKey) : bKey.compareTo(aKey);
    });

    setState(() {
      _displayItems = items;
    });
  }

  Future<void> _initEncryptionKey() async {
    try {
      String? keyString = await _secureStorage.read(key: _keyStorageName);
      if (keyString == null) {
        final key = encrypt.Key.fromSecureRandom(32);
        await _secureStorage.write(
          key: _keyStorageName,
          value: base64UrlEncode(key.bytes),
        );
        _aesKey = key;
        print('New encryption key created');
      } else {
        _aesKey = encrypt.Key(base64Url.decode(keyString));
        print('Encryption key loaded');
      }
    } catch (e) {
      print('Error initializing encryption key: $e');
      _aesKey = encrypt.Key.fromSecureRandom(32);
    }
  }

  Future<void> _loadAllData() async {
    try {
      await _loadEncryptedTextPosts();
      await _loadEncryptedImages();
      await _addDefaultItemsIfNeeded();
      print('Loaded ${_mediaItems.length} total items');
    } catch (e) {
      print('Error loading data: $e');
    }
  }

  Future<void> _addDefaultItemsIfNeeded() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final flagFile = File('${dir.path}/first_run_complete.flag');

      if (!await flagFile.exists()) {
        final defaultItems = [
          {
            'id': 1,
            'type': 'image',
            'thumbnail': Icons.image,
            'title': 'Image 1'
          },
          {
            'id': 2,
            'type': 'text',
            'thumbnail': Icons.text_fields,
            'title': 'Welcome Post',
            'text':
                'Welcome to PrivGuard! Contact us at support@privguard.com or call (555) 123-4567.'
          },
          {
            'id': 3,
            'type': 'image',
            'thumbnail': Icons.image,
            'title': 'Image 2'
          },
          {
            'id': 4,
            'type': 'video',
            'thumbnail': Icons.videocam,
            'title': 'Video 1'
          },
          {
            'id': 5,
            'type': 'text',
            'thumbnail': Icons.text_fields,
            'title': 'Test Data',
            'text':
                'My email is john.doe@example.com and my phone is +1-555-987-6543. I live at 123 Main Street.'
          },
        ];

        _mediaItems.addAll(defaultItems);
        await _saveEncryptedTextPosts();
        await flagFile.writeAsString('completed');
      }
    } catch (e) {
      print('Error adding default items: $e');
    }
  }

  Future<void> _loadEncryptedTextPosts() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final textFile = File('${dir.path}/$_textPostsFileName');

      if (await textFile.exists()) {
        final encryptedBytes = await textFile.readAsBytes();
        final decryptedJson = await _decryptData(encryptedBytes);
        final List<dynamic> textPosts = json.decode(decryptedJson);

        for (var post in textPosts) {
          _mediaItems.add({
            'id': post['id'],
            'type': 'text',
            'thumbnail': Icons.text_fields,
            'title': post['title'],
            'text': post['text'],
          });
        }
      }
    } catch (e) {
      print('Error loading encrypted text posts: $e');
    }
  }

  Future<void> _loadEncryptedImages() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = Directory(dir.path).listSync();

      for (var file in files) {
        if (file.path.endsWith('.enc') && !file.path.contains('text_posts')) {
          final baseName = file.path.split('/').last.replaceFirst('.enc', '');
          // skip meta files (they end with .meta.enc)
          if (baseName.endsWith('.meta')) continue;

          String storageName =
              baseName; // storage identifier (new files use timestamp_+name)
          String? caption;
          String? originalName;
          try {
            final metaPath = '${dir.path}/$storageName.meta.enc';
            final metaFile = File(metaPath);
            if (await metaFile.exists()) {
              final metaBytes = await metaFile.readAsBytes();
              final metaJson = await _decryptData(metaBytes);
              final meta = json.decode(metaJson);
              caption = meta['caption'] as String?;
              originalName = meta['fileName'] as String?;
            }
          } catch (e) {
            // ignore metadata read errors
          }

          _mediaItems.add({
            'id': DateTime.now().millisecondsSinceEpoch + _mediaItems.length,
            'type': 'image',
            'thumbnail': Icons.image,
            'title': originalName ?? storageName,
            'encryptedPath': file.path,
            'fileName': originalName ?? storageName,
            'storageName': storageName,
            'caption': caption,
          });
        }
      }
    } catch (e) {
      print('Error loading encrypted images: $e');
    }
  }

  Future<void> _saveEncryptedTextPosts() async {
    try {
      if (_aesKey == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final textFile = File('${dir.path}/$_textPostsFileName');

      final textPosts = _mediaItems
          .where((item) => item['type'] == 'text')
          .map((item) => {
                'id': item['id'],
                'title': item['title'],
                'text': item['text'],
              })
          .toList();

      if (textPosts.isNotEmpty) {
        final jsonString = json.encode(textPosts);
        final encryptedBytes = await _encryptData(jsonString);
        await textFile.writeAsBytes(encryptedBytes);
      }
    } catch (e) {
      print('Error saving encrypted text posts: $e');
    }
  }

  Future<Uint8List> _encryptData(String data) async {
    if (_aesKey == null) throw Exception('Encryption key not initialized');
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter =
        encrypt.Encrypter(encrypt.AES(_aesKey!, mode: encrypt.AESMode.cbc));
    final encrypted = encrypter.encrypt(data, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  Future<String> _decryptData(Uint8List encryptedData) async {
    if (_aesKey == null) throw Exception('Encryption key not initialized');
    final iv = encrypt.IV(encryptedData.sublist(0, 16));
    final encryptedContent = encryptedData.sublist(16);
    final encrypter =
        encrypt.Encrypter(encrypt.AES(_aesKey!, mode: encrypt.AESMode.cbc));
    return encrypter.decrypt(encrypt.Encrypted(encryptedContent), iv: iv);
  }

  Future<String> _saveEncryptedImage(
      Uint8List imageBytes, String fileName) async {
    if (_aesKey == null) throw Exception('Encryption key not initialized');
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter =
        encrypt.Encrypter(encrypt.AES(_aesKey!, mode: encrypt.AESMode.cbc));
    final encrypted = encrypter.encryptBytes(imageBytes, iv: iv);
    final dir = await getApplicationDocumentsDirectory();
    // Use a unique storage name to avoid filename collisions
    final storageName = '${DateTime.now().millisecondsSinceEpoch}_$fileName';
    final filePath = '${dir.path}/$storageName.enc';
    final file = File(filePath);
    await file.writeAsBytes([...iv.bytes, ...encrypted.bytes]);
    return filePath;
  }

  Future<void> _saveImageMetadata(
      String storageName, Map<String, dynamic> metadata) async {
    if (_aesKey == null) throw Exception('Encryption key not initialized');
    final dir = await getApplicationDocumentsDirectory();
    final metaFile = File('${dir.path}/$storageName.meta.enc');
    final jsonString = json.encode(metadata);
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter =
        encrypt.Encrypter(encrypt.AES(_aesKey!, mode: encrypt.AESMode.cbc));
    final encrypted = encrypter.encrypt(jsonString, iv: iv);
    await metaFile.writeAsBytes([...iv.bytes, ...encrypted.bytes]);
  }

  Future<void> _deleteImageMetadata(String storageName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final metaFile = File('${dir.path}/$storageName.meta.enc');
      if (await metaFile.exists()) await metaFile.delete();
    } catch (e) {
      // ignore
    }
  }

  Future<Uint8List> _loadAndDecryptImage(String encryptedPath) async {
    if (_aesKey == null) throw Exception('Encryption key not initialized');
    final file = File(encryptedPath);
    final bytes = await file.readAsBytes();
    final iv = encrypt.IV(bytes.sublist(0, 16));
    final encryptedData = bytes.sublist(16);
    final encrypter =
        encrypt.Encrypter(encrypt.AES(_aesKey!, mode: encrypt.AESMode.cbc));
    final decrypted =
        encrypter.decryptBytes(encrypt.Encrypted(encryptedData), iv: iv);
    return Uint8List.fromList(decrypted);
  }

  void _addTextPost(String text) async {
    if (!mounted || text.isEmpty) return;

    final newPost = {
      'id': DateTime.now().millisecondsSinceEpoch,
      'type': 'text',
      'thumbnail': Icons.text_fields,
      'title': text.length > 20 ? text.substring(0, 20) + '...' : text,
      'text': text,
    };

    setState(() {
      _mediaItems.add(newPost);
    });

    await _saveEncryptedTextPosts();
  }

  void _deleteItem(Map<String, dynamic> item) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text('Delete ${item['title']}?'),
          content: Text('This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                setState(() {
                  _mediaItems
                      .removeWhere((element) => element['id'] == item['id']);
                });
                _refreshDisplayItems();

                if (item['encryptedPath'] != null) {
                  await File(item['encryptedPath'])
                      .delete()
                      .catchError((_) => File(''));
                  if (item['storageName'] != null) {
                    await _deleteImageMetadata(item['storageName']);
                  }
                }

                if (item['type'] == 'text') {
                  await _saveEncryptedTextPosts();
                }
              },
              child: Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickImageFromGallery() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );
      if (pickedFile != null && mounted) {
        final Uint8List imageBytes = await pickedFile.readAsBytes();
        // Prompt for optional caption before saving
        final caption = await _promptForCaption(initial: '');

        final String encryptedPath =
            await _saveEncryptedImage(imageBytes, pickedFile.name);
        final storageName =
            encryptedPath.split('/').last.replaceFirst('.enc', '');
        if (caption != null && caption.trim().isNotEmpty) {
          await _saveImageMetadata(storageName,
              {'caption': caption.trim(), 'fileName': pickedFile.name});
        }

        setState(() {
          _mediaItems.add({
            'id': DateTime.now().millisecondsSinceEpoch,
            'type': 'image',
            'thumbnail': Icons.image,
            'title': pickedFile.name,
            'fileName': pickedFile.name,
            'storageName': storageName,
            'encryptedPath': encryptedPath,
            'caption': caption?.trim(),
          });
        });
        _refreshDisplayItems();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to pick image: ${e.toString()}'),
            backgroundColor: Colors.red[600],
          ),
        );
      }
    }
  }

  Future<void> _captureImageFromCamera() async {
    try {
      final XFile? capturedFile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
      );
      if (capturedFile != null && mounted) {
        final Uint8List imageBytes = await capturedFile.readAsBytes();
        final caption = await _promptForCaption(initial: '');

        final String encryptedPath =
            await _saveEncryptedImage(imageBytes, capturedFile.name);
        final storageName =
            encryptedPath.split('/').last.replaceFirst('.enc', '');
        if (caption != null && caption.trim().isNotEmpty) {
          await _saveImageMetadata(storageName,
              {'caption': caption.trim(), 'fileName': capturedFile.name});
        }

        setState(() {
          _mediaItems.add({
            'id': DateTime.now().millisecondsSinceEpoch,
            'type': 'image',
            'thumbnail': Icons.image,
            'title': capturedFile.name,
            'fileName': capturedFile.name,
            'storageName': storageName,
            'encryptedPath': encryptedPath,
            'caption': caption?.trim(),
          });
        });
        _refreshDisplayItems();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to capture image: ${e.toString()}'),
            backgroundColor: Colors.red[600],
          ),
        );
      }
    }
  }

  void _showFullContent(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
              maxWidth: MediaQuery.of(context).size.width * 0.9,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // FIXED: Header with proper constraints
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Color(0xFFE0F2FE),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  child: Row(
                    children: [
                      Icon(item['thumbnail'] ?? Icons.help,
                          color: Color(0xFF0C7FF2)),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item['title'] ?? 'Unknown',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0C7FF2),
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: Colors.grey[600]),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(16),
                    child: _buildFullContentWidget(item),
                  ),
                ),
                // FIXED: Properly aligned buttons with constraints
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Color(0xFFF1F5F9),
                    borderRadius:
                        BorderRadius.vertical(bottom: Radius.circular(16)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    ScanAnalysisScreen(mediaItem: item),
                              ),
                            );
                          },
                          icon: Icon(Icons.scanner, size: 18),
                          label: Text('Scan'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Color(0xFF0C7FF2),
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _onLongPress(item);
                          },
                          icon: Icon(Icons.more_horiz, size: 18),
                          label: Text('Options'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Color(0xFF0C7FF2),
                            padding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFullContentWidget(Map<String, dynamic> item) {
    switch (item['type']) {
      case 'text':
        return Container(
          width: double.infinity,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Color(0xFFE2E8F0)),
                  ),
                  child: Text(
                    item['text'] ?? 'No content available',
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.5,
                      color: Color(0xFF334155),
                    ),
                  ),
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.lock, size: 16, color: Color(0xFF10B981)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Encrypted and stored securely',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF10B981),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      case 'image':
        return Container(
          width: double.infinity,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                constraints: BoxConstraints(
                  maxHeight: 400,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _buildImageWidget(item, isFullView: true),
                ),
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.image, size: 16, color: Color(0xFF64748B)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Image • ${item['fileName'] ?? 'Unknown file'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (item['caption'] != null &&
                  (item['caption'] as String).isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(Icons.note, size: 14, color: Color(0xFF94A3B8)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item['caption'],
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF475569),
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      case 'video':
        return Container(
          width: double.infinity,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                height: 300,
                decoration: BoxDecoration(
                  color: Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.play_circle_outline,
                        size: 64,
                        color: Color(0xFF0C7FF2),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Video Preview',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF334155),
                        ),
                      ),
                      SizedBox(height: 8),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Tap to play (video player not implemented)',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.videocam, size: 16, color: Color(0xFF64748B)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Video • Duration: 1:23',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      default:
        return Container(
          width: double.infinity,
          child: Center(
            child: Text(
              'Content type not supported',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
          ),
        );
    }
  }

  Future<String?> _promptForTextEdit({required String initial}) async {
    String? result;
    final TextEditingController controller =
        TextEditingController(text: initial);
    bool disposed = false;

    await showDialog<String?>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text('Edit Text Post'),
          content: TextField(
            controller: controller,
            maxLines: 3,
            maxLength: 1000,
            decoration: InputDecoration(
              hintText: 'Edit your text post',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                result = controller.text;
                Navigator.of(dialogContext).pop();
              },
              child: Text('Save'),
            ),
          ],
        );
      },
    );

    if (!disposed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
        disposed = true;
      });
    }

    return result;
  }

  void _onLongPress(Map<String, dynamic> item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(item['thumbnail'] ?? Icons.help,
                            color: Color(0xFF0C7FF2)),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            item['title'] ?? 'Unknown',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20),
                    ListTile(
                      leading: Icon(Icons.scanner, color: Color(0xFF0C7FF2)),
                      title: Text('Scan for Privacy Risks'),
                      subtitle: Text('Analyze this item before posting'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                ScanAnalysisScreen(mediaItem: item),
                          ),
                        );
                      },
                    ),
                    if (item['type'] == 'text')
                      ListTile(
                        leading: Icon(Icons.edit, color: Color(0xFF0C7FF2)),
                        title: Text('Edit text'),
                        subtitle: Text('Modify the text content'),
                        onTap: () async {
                          Navigator.pop(context);
                          final newText = await _promptForTextEdit(
                              initial: item['text'] ?? '');
                          if (newText != null) {
                            setState(() {
                              item['text'] = newText.trim();
                              item['title'] = newText.trim().length > 20
                                  ? newText.trim().substring(0, 20) + '...'
                                  : newText.trim();
                            });
                            await _saveEncryptedTextPosts();
                            _refreshDisplayItems();
                          }
                        },
                      ),
                    // Only show caption option for image posts
                    if (item['type'] == 'image')
                      ListTile(
                        leading: Icon(Icons.edit, color: Color(0xFF0C7FF2)),
                        title: Text('Edit caption'),
                        subtitle:
                            Text('Add or modify the image caption/description'),
                        onTap: () async {
                          Navigator.pop(context);
                          final newCaption = await _promptForCaption(
                              initial: item['caption'] ?? '');
                          if (newCaption != null) {
                            setState(() {
                              item['caption'] = newCaption.trim();
                            });
                            final storageName =
                                item['storageName'] ?? item['fileName'];
                            if ((newCaption.trim()).isEmpty) {
                              await _deleteImageMetadata(storageName);
                            } else {
                              await _saveImageMetadata(storageName, {
                                'caption': newCaption.trim(),
                                'fileName': item['fileName'] ?? storageName
                              });
                            }
                            _refreshDisplayItems();
                          }
                        },
                      ),
                    ListTile(
                      leading: Icon(Icons.delete, color: Colors.red[600]),
                      title: Text('Delete'),
                      subtitle: Text('Remove this item permanently'),
                      onTap: () {
                        Navigator.pop(context);
                        _deleteItem(item);
                      },
                    ),
                    SizedBox(height: 20),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _toggleAddOptions() {
    setState(() {
      _showAddOptions = !_showAddOptions;
    });
    if (_showAddOptions) {
      _fabAnimationController.forward();
    } else {
      _fabAnimationController.reverse();
    }
  }

  void _showCreateTextPostDialog() {
    final TextEditingController textController = TextEditingController();
    bool isDisposed = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text("Create Text Post"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: textController,
                maxLines: 3,
                maxLength: 1000,
                decoration: InputDecoration(
                  hintText: "What's on your mind?",
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                if (!isDisposed) {
                  Future.delayed(Duration(milliseconds: 100), () {
                    textController.dispose();
                    isDisposed = true;
                  });
                }
              },
              child: Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                final text = textController.text.trim();
                if (text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Please enter some text'),
                      backgroundColor: Colors.orange[600],
                    ),
                  );
                  return;
                }

                final textToPost = text;
                Navigator.of(dialogContext).pop();

                if (!isDisposed) {
                  Future.delayed(Duration(milliseconds: 100), () {
                    textController.dispose();
                    isDisposed = true;
                    _addTextPost(textToPost);
                  });
                }
              },
              child: Text("Post"),
            ),
          ],
        );
      },
    ).then((_) {
      if (!isDisposed) {
        Future.delayed(Duration(milliseconds: 100), () {
          textController.dispose();
          isDisposed = true;
        });
      }
    });
  }

  Widget _buildImageWidget(Map<String, dynamic> item,
      {bool isFullView = false}) {
    if (item['encryptedPath'] != null) {
      return FutureBuilder<Uint8List>(
        future: _loadAndDecryptImage(item['encryptedPath']),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(isFullView ? 12 : 12),
              child: Image.memory(
                snapshot.data!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              ),
            );
          } else if (snapshot.hasError) {
            return Center(
              child: Icon(
                Icons.error,
                size: isFullView ? 64 : 32,
                color: Colors.red,
              ),
            );
          }
          return Center(
            child: CircularProgressIndicator(),
          );
        },
      );
    } else {
      return Center(
        child: Icon(
          item['thumbnail'] ?? Icons.help,
          size: isFullView ? 64 : 32,
          color: Color(0xFF0C7FF2),
        ),
      );
    }
  }

  Future<String?> _promptForCaption({required String initial}) async {
    String? result;
    final TextEditingController controller =
        TextEditingController(text: initial);
    bool disposed = false;

    await showDialog<String?>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text('Image caption'),
          content: TextField(
            controller: controller,
            maxLines: 3,
            maxLength: 500,
            decoration: InputDecoration(
              hintText: 'Add a caption or short description (optional)',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                result = controller.text;
                Navigator.of(dialogContext).pop();
              },
              child: Text('Save'),
            ),
          ],
        );
      },
    );

    if (!disposed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
        disposed = true;
      });
    }

    return result;
  }

  Widget _buildTextContentWidget(Map<String, dynamic> item) {
    return Container(
      padding: EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.text_fields, size: 14, color: Color(0xFF0C7FF2)),
              SizedBox(width: 4),
              Icon(Icons.lock, size: 12, color: Color(0xFF10B981)),
            ],
          ),
          SizedBox(height: 4),
          Expanded(
            child: Text(
              item['text'] ?? 'No content',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF334155),
                height: 1.2,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Color(0xFFF3F4F6),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          shadowColor: Colors.black26,
          // REMOVED: leading close button
          automaticallyImplyLeading: false,
          title: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield, color: Color(0xFF0C7FF2), size: 24),
              SizedBox(width: 8),
              Text(
                'PrivGuard',
                style: TextStyle(
                  color: Color(0xFF334155),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          centerTitle: true,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFF0C7FF2)),
              SizedBox(height: 16),
              Text('Loading encrypted data...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Color(0xFFF3F4F6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.black26,
        // REMOVED: leading close button
        automaticallyImplyLeading: false,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield, color: Color(0xFF0C7FF2), size: 24),
            SizedBox(width: 8),
            Text(
              'PrivGuard',
              style: TextStyle(
                color: Color(0xFF334155),
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gallery',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF334155),
                    ),
                  ),
                  SizedBox(height: 16),
                  Expanded(
                    child: _displayItems.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.photo_library_outlined,
                                  size: 80,
                                  color: Color(0xFF94A3B8),
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'No media yet',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Add or capture media to get started',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Color(0xFF94A3B8),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Column(
                            children: [
                              Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _searchController,
                                        decoration: InputDecoration(
                                          hintText:
                                              'Search by caption or title',
                                          prefixIcon: Icon(Icons.search),
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          isDense: true,
                                        ),
                                        onChanged: (_) =>
                                            _refreshDisplayItems(),
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    IconButton(
                                      onPressed: () {
                                        _sortAscending = !_sortAscending;
                                        _refreshDisplayItems();
                                      },
                                      icon: Icon(
                                        _sortAscending
                                            ? Icons.sort_by_alpha
                                            : Icons.sort,
                                        color: Color(0xFF0C7FF2),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: GridView.builder(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                    childAspectRatio: 1.0,
                                  ),
                                  itemCount: _displayItems.length,
                                  itemBuilder: (context, index) {
                                    final item = _displayItems[index];
                                    return GestureDetector(
                                      onTap: () => _showFullContent(item),
                                      onLongPress: () => _onLongPress(item),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          boxShadow: [
                                            BoxShadow(
                                              color:
                                                  Colors.black.withOpacity(0.1),
                                              blurRadius: 4,
                                              offset: Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: Stack(
                                            children: [
                                              if (item['type'] == 'image')
                                                _buildImageWidget(item)
                                              else if (item['type'] == 'text')
                                                Container(
                                                  color: Colors.white,
                                                  child:
                                                      _buildTextContentWidget(
                                                          item),
                                                )
                                              else
                                                Container(
                                                  color: Colors.white,
                                                  child: Center(
                                                    child: Icon(
                                                      item['thumbnail'] ??
                                                          Icons.help,
                                                      size: 32,
                                                      color: Color(0xFF0C7FF2),
                                                    ),
                                                  ),
                                                ),
                                              if (item['type'] == 'video')
                                                Positioned(
                                                  bottom: 4,
                                                  right: 4,
                                                  child: Container(
                                                    padding:
                                                        EdgeInsets.symmetric(
                                                            horizontal: 4,
                                                            vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black54,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              4),
                                                    ),
                                                    child: Text(
                                                      '1:23',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 10,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: Stack(
        children: [
          if (_showAddOptions) ...[
            Positioned(
              bottom: 160,
              right: 0,
              child: AnimatedBuilder(
                animation: _fabAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _fabAnimation.value,
                    child: Opacity(
                      opacity: _fabAnimation.value,
                      child: Container(
                        margin: EdgeInsets.only(bottom: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.1),
                                    blurRadius: 4,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                'Upload',
                                style: TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            FloatingActionButton(
                              mini: true,
                              backgroundColor: Colors.white,
                              onPressed: () {
                                _toggleAddOptions();
                                _pickImageFromGallery();
                              },
                              child: Icon(Icons.upload_file,
                                  color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              bottom: 110,
              right: 0,
              child: AnimatedBuilder(
                animation: _fabAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _fabAnimation.value,
                    child: Opacity(
                      opacity: _fabAnimation.value,
                      child: Container(
                        margin: EdgeInsets.only(bottom: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.1),
                                    blurRadius: 4,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                'Capture',
                                style: TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            FloatingActionButton(
                              mini: true,
                              backgroundColor: Colors.white,
                              onPressed: () {
                                _toggleAddOptions();
                                _captureImageFromCamera();
                              },
                              child: Icon(Icons.photo_camera,
                                  color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              bottom: 60,
              right: 0,
              child: AnimatedBuilder(
                animation: _fabAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _fabAnimation.value,
                    child: Opacity(
                      opacity: _fabAnimation.value,
                      child: Container(
                        margin: EdgeInsets.only(bottom: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.1),
                                    blurRadius: 4,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                'Text Post',
                                style: TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            FloatingActionButton(
                              mini: true,
                              backgroundColor: Colors.white,
                              onPressed: () {
                                _toggleAddOptions();
                                _showCreateTextPostDialog();
                              },
                              child: Icon(Icons.edit_note,
                                  color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          Positioned(
            bottom: 0,
            right: 0,
            child: FloatingActionButton(
              backgroundColor: Color(0xFF0C7FF2),
              onPressed: _toggleAddOptions,
              child: AnimatedBuilder(
                animation: _fabAnimation,
                builder: (context, child) {
                  return Transform.rotate(
                    angle:
                        _fabAnimation.value * 0.785398, // 45 degrees in radians
                    child: Icon(
                      Icons.add,
                      color: Colors.white,
                      size: 28,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}


