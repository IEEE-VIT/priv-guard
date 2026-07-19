import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// Extracts text from encrypted image posts using on-device OCR (Google ML Kit).
///
/// All processing happens on-device — no image or extracted text ever leaves
/// the phone, preserving PrivGuard's privacy guarantee. Images are stored
/// AES-encrypted (see GalleryScreen), so this service decrypts them in memory,
/// hands the plaintext to ML Kit via a short-lived temp file, and deletes that
/// temp file immediately afterwards so decrypted content is never left on disk.
class ImageOcrService {
  // Must match the key name used by GalleryScreen when persisting images.
  static const String _keyStorageName = 'gallery_aes_key';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// Reads the AES key that GalleryScreen used to encrypt images.
  /// Returns null if no key has been created yet (nothing to decrypt).
  static Future<encrypt.Key?> _loadKey() async {
    final keyString = await _secureStorage.read(key: _keyStorageName);
    if (keyString == null) return null;
    return encrypt.Key(base64Url.decode(keyString));
  }

  /// Decrypts an encrypted image file. Mirrors GalleryScreen's storage format:
  /// the first 16 bytes are the IV, the remainder is AES-CBC ciphertext.
  static Future<Uint8List> _decryptImage(
      String encryptedPath, encrypt.Key key) async {
    final bytes = await File(encryptedPath).readAsBytes();
    final iv = encrypt.IV(bytes.sublist(0, 16));
    final ciphertext = bytes.sublist(16);
    final encrypter =
        encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    final decrypted =
        encrypter.decryptBytes(encrypt.Encrypted(ciphertext), iv: iv);
    return Uint8List.fromList(decrypted);
  }

  /// Runs OCR on an encrypted image and returns the recognized text.
  ///
  /// Returns an empty string if the image contains no readable text, if the
  /// encryption key is unavailable, or if anything fails — callers should treat
  /// an empty result as "no text found" rather than an error.
  static Future<String> extractTextFromEncryptedImage(
      String encryptedPath) async {
    File? tempFile;
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final key = await _loadKey();
      if (key == null) return '';

      final imageBytes = await _decryptImage(encryptedPath, key);

      // ML Kit's InputImage.fromFilePath is the most reliable entry point for
      // arbitrary JPEG/PNG bytes (fromBytes requires exact width/height/rotation
      // metadata). Write the decrypted bytes to a temp file just long enough to
      // run recognition, then delete it in the finally block below.
      final tmpDir = await getTemporaryDirectory();
      tempFile = File(
          '${tmpDir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.img');
      await tempFile.writeAsBytes(imageBytes, flush: true);

      final inputImage = InputImage.fromFilePath(tempFile.path);
      final RecognizedText result = await recognizer.processImage(inputImage);
      return result.text.trim();
    } catch (_) {
      return '';
    } finally {
      await recognizer.close();
      if (tempFile != null) {
        try {
          await tempFile.delete();
        } catch (_) {
          // Best-effort cleanup; ignore if the temp file is already gone.
        }
      }
    }
  }
}
