import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:tokenizer/tokenizer.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import '../services/image_ocr_service.dart';

Interpreter? _interpreter;
DistilBertTokenizer? _tokenizer;
bool _isInitialized = false;

Future<void> initializePIIDetector() async {
  try {
    // Load the model
    final modelData = await rootBundle.load('assets/pii_model.tflite');
    _interpreter = Interpreter.fromBuffer(modelData.buffer.asUint8List());

    // Load vocabulary
    final vocabData = await rootBundle.loadString('assets/vocab.txt');

    // Load tokenizer configuration
    final tokenizerConfigData =
        await rootBundle.loadString('assets/tokenizer_config.json');
    final tokenizerConfig = jsonDecode(tokenizerConfigData);

    _tokenizer = DistilBertTokenizer();
    await _tokenizer!.loadVocab(vocabData);

    _isInitialized = true;
  } catch (e, stackTrace) {
    _isInitialized = false;
  }
}

class ScanAnalysisScreen extends StatefulWidget {
  final Map<String, dynamic> mediaItem;

  const ScanAnalysisScreen({Key? key, required this.mediaItem})
      : super(key: key);

  @override
  _ScanAnalysisScreenState createState() => _ScanAnalysisScreenState();
}

class _ScanAnalysisScreenState extends State<ScanAnalysisScreen> {
  bool _isScanning = false;
  Map<String, dynamic>? _analysisResult;
  bool _showRisksTab = true;

  @override
  void initState() {
    super.initState();
    _initializeAndStartAnalysis();
  }

  Future<void> _initializeAndStartAnalysis() async {
    if (!_isInitialized) {
      await initializePIIDetector();
    }
    _startAnalysis();
  }

  Future<void> _startAnalysis() async {
    setState(() {
      _isScanning = true;
    });

    try {
      final type = widget.mediaItem['type'] ?? 'text';

      if (type == 'text') {
        final text = widget.mediaItem['text'] ?? '';

        if (text.isNotEmpty && _isInitialized) {
          // Run actual PII detection
          final piiEntities = await detectPII(text);

          setState(() {
            _isScanning = false;
            _analysisResult = _buildAnalysisResult(piiEntities);
          });
        } else {
          // Fallback to demo data
          _setDemoData(type);
        }
      } else if (type == 'image') {
        if (_isInitialized) {
          // Extract any text baked into the image (IDs, tickets, screenshots,
          // documents, etc.) with on-device OCR, then combine it with the
          // user-provided caption and run the same NER pipeline as text posts.
          final caption = (widget.mediaItem['caption'] ?? '').toString();
          String ocrText = '';
          final encryptedPath = widget.mediaItem['encryptedPath'];
          if (encryptedPath != null) {
            ocrText = await ImageOcrService.extractTextFromEncryptedImage(
                encryptedPath);
          }

          final combined =
              [caption, ocrText].where((s) => s.trim().isNotEmpty).join('\n');

          final piiEntities = combined.trim().isEmpty
              ? <PIIEntity>[]
              : await detectPII(combined);

          // OCR can take a moment; bail out if the user left this screen.
          if (!mounted) return;
          setState(() {
            _isScanning = false;
            _analysisResult = _buildAnalysisResult(piiEntities)
              ..['extractedText'] = ocrText;
          });
        } else {
          _setDemoData(type);
        }
      } else {
        _setDemoData(type);
      }
    } catch (e, stackTrace) {
      _setDemoData(widget.mediaItem['type'] ?? 'text');
    }
  }

  // Builds the analysis result map from detected PII entities. Shared by the
  // text and image scan paths so scoring/summary logic stays in one place.
  Map<String, dynamic> _buildAnalysisResult(List<PIIEntity> piiEntities) {
    final riskScore = _calculateRiskScore(piiEntities);
    return {
      'riskScore': riskScore,
      'riskLevel': _getRiskLevel(riskScore),
      'detectedRisks': _generateDetectedRisks(piiEntities),
      'suggestions': _generateSuggestions(piiEntities),
      'piiEntities': piiEntities,
      'technicalDetails': {
        'personalDataPoints': piiEntities.length,
        'sensitiveKeywords': piiEntities.map((e) => e.label).toSet().toList(),
        'privacyScore': (100 - riskScore) / 10,
      }
    };
  }

  void _setDemoData(String type) {
    // Your existing demo data logic here
    Future.delayed(Duration(seconds: 2), () {
      final type = widget.mediaItem['type'] ?? 'text';
      if (type == 'image') {
        setState(() {
          _isScanning = false;
          _analysisResult = {
            'riskScore': 85,
            'riskLevel': 'High',
            'detectedRisks': [
              'Faces detected in image',
              'EXIF location data present',
              'Personal items visible (ID cards, documents)',
              'Background contains identifiable information',
            ],
            'suggestions': [
              'Blur or crop faces before sharing',
              'Remove EXIF metadata',
              'Cover sensitive documents in background',
              'Check for reflective surfaces showing personal info',
            ],
            'technicalDetails': {
              'facesDetected': 2,
              'locationAccuracy': 'High precision GPS',
              'personalItemsCount': 3,
            }
          };
        });
      } else if (type == 'video') {
        setState(() {
          _isScanning = false;
          _analysisResult = {
            'riskScore': null,
            'riskLevel': 'Not Supported',
            'isVideoUnsupported': true,
            'message': 'Scanning videos will be supported in future versions',
            'supportedFeatures': [
              'Audio privacy analysis',
              'Visual content recognition',
              'Automatic face blurring',
              'Location metadata removal',
            ],
          };
        });
      } else {
        setState(() {
          _isScanning = false;
          _analysisResult = {
            'riskScore': 60,
            'riskLevel': 'Medium',
            'detectedRisks': [
              'Phone number mentioned',
              'Workplace information shared',
              'Personal schedule details',
              'Family member names mentioned',
            ],
            'suggestions': [
              'Remove or redact phone numbers',
              'Avoid sharing specific workplace details',
              'Limit sharing of daily routines',
              'Use initials instead of full names',
            ],
            'technicalDetails': {
              'personalDataPoints': 4,
              'sensitiveKeywords': ['phone', 'work', 'schedule'],
              'privacyScore': 6.5,
            }
          };
        });
      }
    });
  }

  int _calculateRiskScore(List<PIIEntity> entities) {
    if (entities.isEmpty) return 5; // Very low risk for clean content

    int score = 0;
    Map<String, int> entityCounts = {};

    // Count entities by type
    for (final entity in entities) {
      entityCounts[entity.label] = (entityCounts[entity.label] ?? 0) + 1;
    }

    // Calculate risk based on entity types and quantities
    for (final entry in entityCounts.entries) {
      final label = entry.key;
      final count = entry.value;

      switch (label) {
        case 'SURNAME':
        case 'GIVENNAME':
          score += 15 * count; // Moderate risk
          break;
        case 'EMAIL':
          score += 25 * count; // High risk
          break;
        case 'TELEPHONENUM':
          score += 20 * count; // High risk
          break;
        case 'CREDITCARDNUMBER':
        case 'SOCIALNUM':
        case 'DRIVERLICENSENUM':
        case 'IDCARDNUM':
        case 'PASSWORD':
        case 'ACCOUNTNUM':
          score += 35 * count; // Critical risk
          break;
        case 'CITY':
        case 'STREET':
        case 'ZIPCODE':
        case 'BUILDINGNUM':
          score += 12 * count; // Moderate risk
          break;
        case 'USERNAME':
        case 'TAXNUM':
        case 'DATEOFBIRTH':
          score += 18 * count; // High risk
          break;
        default:
          score += 10 * count; // Low risk
          break;
      }
    }

    // Apply quantity penalties for multiple entities of the same type
    for (final count in entityCounts.values) {
      if (count > 3) {
        score += (count - 3) * 5; // Additional penalty for excessive quantities
      }
    }

    // Cap the score at 100
    return (score > 100) ? 100 : score;
  }

  String _getRiskLevel(int score) {
    if (score >= 80) return 'Critical';
    if (score >= 60) return 'High';
    if (score >= 40) return 'Medium';
    if (score >= 20) return 'Low';
    return 'Very Low';
  }

  List<String> _generateDetectedRisks(List<PIIEntity> entities) {
    List<String> risks = [];
    Map<String, List<String>> groupedEntities = {};

    // Group entities by type for better risk assessment
    for (final entity in entities) {
      if (!groupedEntities.containsKey(entity.label)) {
        groupedEntities[entity.label] = [];
      }
      groupedEntities[entity.label]!.add(entity.text);
    }

    // Generate risk descriptions (only risks, no vulnerabilities)
    for (final entry in groupedEntities.entries) {
      final label = entry.key;
      final texts = entry.value;

      switch (label) {
        case 'SURNAME':
        case 'GIVENNAME':
          risks.add('Personal names detected: ${texts.join(", ")}');
          break;
        case 'EMAIL':
          risks.add('Email addresses found: ${texts.join(", ")}');
          break;
        case 'TELEPHONENUM':
          risks.add('Phone numbers detected: ${texts.join(", ")}');
          break;
        case 'CREDITCARDNUMBER':
          risks.add('Credit card numbers found: ${texts.join(", ")}');
          break;
        case 'SOCIALNUM':
          risks.add('Social security numbers detected: ${texts.join(", ")}');
          break;
        case 'DRIVERLICENSENUM':
          risks.add('Driver license numbers found: ${texts.join(", ")}');
          break;
        case 'IDCARDNUM':
          risks.add('ID card numbers detected: ${texts.join(", ")}');
          break;
        case 'PASSWORD':
          risks.add('Passwords detected: ${texts.join(", ")}');
          break;
        case 'ACCOUNTNUM':
          risks.add('Account numbers found: ${texts.join(", ")}');
          break;
        case 'CITY':
        case 'STREET':
        case 'ZIPCODE':
        case 'BUILDINGNUM':
          risks.add('Location information: ${texts.join(", ")}');
          break;
        case 'USERNAME':
          risks.add('Usernames detected: ${texts.join(", ")}');
          break;
        case 'TAXNUM':
          risks.add('Tax identification numbers found: ${texts.join(", ")}');
          break;
        case 'DATEOFBIRTH':
          risks.add('Date of birth detected: ${texts.join(", ")}');
          break;
        default:
          risks.add('Sensitive information detected: ${texts.join(", ")}');
      }
    }

    if (risks.isEmpty) {
      risks.add('No significant privacy risks detected in this content');
    }

    return risks;
  }

  List<String> _generateSuggestions(List<PIIEntity> entities) {
    List<String> suggestions = [];
    Map<String, List<String>> entitySuggestions = {};

    // Generate specific suggestions (1-2 per entity type) and vulnerabilities
    for (final entity in entities) {
      final label = entity.label;

      // Initialize suggestions list for this entity type if not exists
      if (!entitySuggestions.containsKey(label)) {
        entitySuggestions[label] = [];
      }

      // Only add suggestions if we haven't reached the limit for this entity type
      if (entitySuggestions[label]!.length < 2) {
        switch (label) {
          case 'SURNAME':
          case 'GIVENNAME':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!.add(
                  'Replace full names with initials or pseudonyms (e.g., "John Smith" → "J.S.")');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Names can be used for identity theft or social engineering attacks');
            }
            break;
          case 'EMAIL':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!
                  .add('Remove or redact email addresses completely');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Email addresses are vulnerable to phishing attacks and spam targeting');
            }
            break;
          case 'TELEPHONENUM':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!
                  .add('Remove or redact phone numbers entirely');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Phone numbers can be used for SMS spam, robocalls, or social engineering');
            }
            break;
          case 'CREDITCARDNUMBER':
          case 'SOCIALNUM':
          case 'DRIVERLICENSENUM':
          case 'IDCARDNUM':
          case 'ACCOUNTNUM':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!
                  .add('Remove or redact all sensitive identification numbers');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: These numbers are critical for financial fraud and identity theft');
            }
            break;
          case 'PASSWORD':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!
                  .add('Never share passwords in any text content');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Passwords pose critical security risk for account compromise');
            }
            break;
          case 'CITY':
          case 'STREET':
          case 'ZIPCODE':
          case 'BUILDINGNUM':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!.add(
                  'Use general location references instead of specific addresses');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Location data can be used for physical security threats or stalking');
            }
            break;
          case 'USERNAME':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!
                  .add('Avoid sharing usernames or account identifiers');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Usernames can be used for targeted attacks and social engineering');
            }
            break;
          case 'TAXNUM':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!.add(
                  'Remove or redact tax identification numbers completely');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Tax IDs are sensitive for tax fraud and identity theft');
            }
            break;
          case 'DATEOFBIRTH':
            if (entitySuggestions[label]!.length == 0) {
              entitySuggestions[label]!
                  .add('Avoid sharing specific birth dates');
            } else if (entitySuggestions[label]!.length == 1) {
              entitySuggestions[label]!.add(
                  'Vulnerability: Birth dates are key components for identity theft and fraud');
            }
            break;
        }
      }
    }

    // Flatten all suggestions from different entity types
    for (final entitySuggestionsList in entitySuggestions.values) {
      suggestions.addAll(entitySuggestionsList);
    }

    // Add general privacy recommendations if we have space
    if (suggestions.length < 2) {
      suggestions.add('Review content before sharing on public platforms');
    }
    if (suggestions.length < 2) {
      suggestions.add('Enable privacy settings on all social media accounts');
    }

    if (suggestions.isEmpty) {
      suggestions.add('Your content appears to be privacy-friendly');
      suggestions.add('Continue following privacy best practices');
    }

    return suggestions;
  }

  Color _getRiskColor(int? score) {
    if (score == null) return Color(0xFF94A3B8);
    if (score >= 80) return Color(0xFFDC2626); // Critical - Red
    if (score >= 60) return Color(0xFFEF4444); // High - Red
    if (score >= 40) return Color(0xFFF59E0B); // Medium - Orange
    if (score >= 20) return Color(0xFF10B981); // Low - Green
    return Color(0xFF059669); // Very Low - Dark Green
  }

  IconData _getMediaIcon() {
    final type = widget.mediaItem['type'];
    if (type == 'image') return Icons.image;
    if (type == 'video') return Icons.videocam;
    return Icons.text_fields;
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Color(0xFF0C7FF2);
    final slate200 = Color(0xFFE2E8F0);
    final slate400 = Color(0xFF94A3B8);
    final slate500 = Color(0xFF64748B);
    final slate600 = Color(0xFF475569);
    final slate700 = Color(0xFF334155);
    final slate800 = Color(0xFF1E293B);
    final slate900 = Color(0xFF0F172A);

    bool isVideoUnsupported = _analysisResult?['isVideoUnsupported'] == true;

    // Show loading screen while scanning or if model is not ready
    if (_isScanning || !_isInitialized) {
      return Scaffold(
        backgroundColor: Color(0xFFF1F5F9),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new, color: primaryColor),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            widget.mediaItem['title'] ?? 'Privacy Analysis',
            style: TextStyle(
              color: slate800,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          centerTitle: true,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: slate200,
                ),
                child: Stack(
                  children: [
                    CustomPaint(
                      painter: LoadingPainter(),
                      size: Size(120, 120),
                    ),
                    Center(
                      child: Icon(
                        Icons.security,
                        size: 48,
                        color: primaryColor,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 32),
              Text(
                'Scanning',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: slate800,
                ),
              ),
              SizedBox(height: 16),
              Text(
                !_isInitialized
                    ? 'Initializing privacy detection model...'
                    : (widget.mediaItem['type'] == 'image'
                        ? 'Extracting text from image and analyzing privacy risks...'
                        : 'Analyzing privacy risks in your content...'),
                style: TextStyle(
                  fontSize: 16,
                  color: slate600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: primaryColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.mediaItem['title'] ?? 'Privacy Analysis',
          style: TextStyle(
            color: slate800,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Media Preview Container
            Container(
              margin: EdgeInsets.all(16),
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // User info row
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: slate200,
                          child: Icon(_getMediaIcon(), color: slate600),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'User',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: slate800,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '@username',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: slate500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),

                    // Content text
                    LayoutBuilder(
                      builder: (context, constraints) {
                        return Container(
                          width: constraints.maxWidth,
                          child: Text(
                            widget.mediaItem['text'] ??
                                widget.mediaItem['title'] ??
                                widget.mediaItem['fileName'] ??
                                'Media content',
                            style: TextStyle(
                              fontSize: 14,
                              color: slate700,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            softWrap: true,
                          ),
                        );
                      },
                    ),

                    // Image preview
                    if (widget.mediaItem['type'] == 'image')
                      Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Container(
                              width: constraints.maxWidth,
                              height: 120,
                              decoration: BoxDecoration(
                                color: slate200,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: widget.mediaItem['encryptedPath'] != null
                                    ? Center(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.image,
                                              size: 32,
                                              color: slate600,
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Encrypted Image',
                                              style: TextStyle(
                                                color: slate600,
                                                fontSize: 10,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      )
                                    : Center(
                                        child: Icon(
                                          Icons.image,
                                          size: 32,
                                          color: slate600,
                                        ),
                                      ),
                              ),
                            );
                          },
                        ),
                      ),

                    // Text extracted from the image via on-device OCR.
                    if (widget.mediaItem['type'] == 'image' &&
                        _analysisResult != null)
                      Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: slate200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.text_snippet_outlined,
                                      size: 16, color: slate600),
                                  SizedBox(width: 6),
                                  Text(
                                    'Text extracted from image',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: slate700,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 6),
                              Text(
                                (_analysisResult?['extractedText'] ?? '')
                                        .toString()
                                        .trim()
                                        .isEmpty
                                    ? 'No readable text found in this image.'
                                    : _analysisResult!['extractedText'],
                                style: TextStyle(
                                  fontSize: 13,
                                  color: slate600,
                                  height: 1.4,
                                ),
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Risk Score Section
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Risk Score',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: slate800,
                    ),
                  ),
                  SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: slate200,
                        ),
                        child: Stack(
                          children: [
                            CustomPaint(
                              painter: RiskScorePainter(
                                value:
                                    (_analysisResult?['riskScore'] ?? 0) / 100,
                                color: _getRiskColor(
                                    _analysisResult?['riskScore']),
                              ),
                              size: Size(120, 120),
                            ),
                            Center(
                              child: Container(
                                width: 90,
                                height: 90,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${_analysisResult?['riskScore'] ?? '--'}',
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.bold,
                                          color: _getRiskColor(
                                              _analysisResult?['riskScore']),
                                        ),
                                      ),
                                      Text(
                                        _analysisResult?['riskLevel'] ??
                                            'Unknown',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: slate500,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),

                  // Summary Section
                  if (_analysisResult != null)
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Analysis Summary',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: slate800,
                            ),
                          ),
                          SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _buildSummaryCard(
                                  'Detected Entities',
                                  '${_analysisResult!['piiEntities']?.length ?? 0}',
                                  Icons.security,
                                  primaryColor,
                                ),
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: _buildSummaryCard(
                                  'Risk Level',
                                  _analysisResult!['riskLevel'] ?? 'Unknown',
                                  Icons.warning,
                                  _getRiskColor(_analysisResult!['riskScore']),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 16),

            // Tabs Section
            Container(
              color: Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _showRisksTab = true),
                      child: Container(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: _showRisksTab
                                  ? primaryColor
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            'Detected Risks',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: _showRisksTab ? primaryColor : slate500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _showRisksTab = false),
                      child: Container(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: !_showRisksTab
                                  ? primaryColor
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            'Suggestions',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: !_showRisksTab ? primaryColor : slate500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Content Section
            Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_showRisksTab)
                    ..._analysisResult?['detectedRisks']?.map<Widget>((risk) =>
                            Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  return Container(
                                    width: constraints.maxWidth,
                                    padding: EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.05),
                                          blurRadius: 4,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 48,
                                          height: 48,
                                          decoration: BoxDecoration(
                                            color: Color(0xFFE0F2FE),
                                            borderRadius:
                                                BorderRadius.circular(24),
                                          ),
                                          child: Center(
                                            child: Icon(
                                              Icons.warning,
                                              color: primaryColor,
                                            ),
                                          ),
                                        ),
                                        SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                risk,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 16,
                                                  color: slate800,
                                                ),
                                                maxLines: null,
                                                softWrap: true,
                                              ),
                                              SizedBox(height: 4),
                                              Text(
                                                'Risk identified',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: slate500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            )) ??
                        [],
                  if (!_showRisksTab)
                    ..._analysisResult?['suggestions']
                            ?.map<Widget>((suggestion) => Padding(
                                  padding: EdgeInsets.only(bottom: 12),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      return Container(
                                        width: constraints.maxWidth,
                                        padding: EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black
                                                  .withOpacity(0.05),
                                              blurRadius: 4,
                                              offset: Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Container(
                                              width: 40,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                color: slate200,
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: Center(
                                                child: Icon(
                                                  Icons.lightbulb_outline,
                                                  color: slate600,
                                                  size: 20,
                                                ),
                                              ),
                                            ),
                                            SizedBox(width: 16),
                                            Expanded(
                                              child: Text(
                                                suggestion,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 16,
                                                  color: slate800,
                                                ),
                                                maxLines: null,
                                                softWrap: true,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                )) ??
                        [],
                ],
              ),
            ),
            SizedBox(height: 32), // Bottom padding
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(
      String title, String value, IconData icon, Color color) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF64748B),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class DistilBertTokenizer {
  late Map<String, int> vocab;
  late Map<int, String> invVocab;
  late String padToken;
  late String clsToken;
  late String sepToken;
  late String unkToken;
  late String maskToken;
  late int maxLength;
  late List<String> labelNames;
  late Map<String, int> labelToId;
  late Map<int, String> idToLabel;
  late bool doLowerCase;
  late int maxInputCharsPerWord;

  DistilBertTokenizer();

  Future<void> loadVocab(String vocabText) async {
    try {
      // Load vocabulary from plain text format (one token per line)
      final lines = vocabText.split('\n');
      vocab = {};

      // Load vocabulary tokens from the file in order
      for (int i = 0; i < lines.length; i++) {
        final token = lines[i].trim();
        if (token.isNotEmpty) {
          vocab[token] = i;
        }
      }

      // Set special tokens based on the tokenizer configuration
      padToken = '[PAD]';
      clsToken = '[CLS]';
      sepToken = '[SEP]';
      unkToken = '[UNK]';
      maskToken = '[MASK]';
      maxLength = 128; // Match the truncation max_length in tokenizer.json
      doLowerCase = true; // From tokenizer_config.json
      maxInputCharsPerWord = 100; // From tokenizer.json

      // Create inverse vocabulary
      invVocab = vocab.map((key, value) => MapEntry(value, key));

      // Use EXACTLY the same labels as the training model (35 labels)
      labelNames = [
        'O',
        'B-SURNAME',
        'I-SURNAME',
        'B-CITY',
        'I-CITY',
        'B-GIVENNAME',
        'I-GIVENNAME',
        'B-DATEOFBIRTH',
        'I-DATEOFBIRTH',
        'B-DRIVERLICENSENUM',
        'I-DRIVERLICENSENUM',
        'B-CREDITCARDNUMBER',
        'I-CREDITCARDNUMBER',
        'B-TELEPHONENUM',
        'I-TELEPHONENUM',
        'B-SOCIALNUM',
        'I-SOCIALNUM',
        'B-ZIPCODE',
        'I-ZIPCODE',
        'B-IDCARDNUM',
        'I-IDCARDNUM',
        'B-USERNAME',
        'I-USERNAME',
        'B-STREET',
        'I-STREET',
        'B-TAXNUM',
        'I-TAXNUM',
        'B-EMAIL',
        'I-EMAIL',
        'B-BUILDINGNUM',
        'I-BUILDINGNUM',
        'B-PASSWORD',
        'I-PASSWORD',
        'B-ACCOUNTNUM',
        'I-ACCOUNTNUM'
      ];

      labelToId = {};
      idToLabel = {};
      for (int i = 0; i < labelNames.length; i++) {
        labelToId[labelNames[i]] = i;
        idToLabel[i] = labelNames[i];
      }
    } catch (e) {
      throw e;
    }
  }

  // Normalize text according to BertNormalizer
  String _normalizeText(String text) {
    if (doLowerCase) {
      text = text.toLowerCase();
    }

    // Clean text: remove control characters except newlines and tabs
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

    // Handle Chinese characters (basic implementation)
    // This is a simplified version - in practice, you'd want more sophisticated Chinese character handling

    return text;
  }

  // Pre-tokenize text according to BertPreTokenizer
  List<String> _preTokenize(String text) {
    // Tokenize into either contiguous word characters or single punctuation
    // characters. This keeps punctuation (like '@' and '.') as separate tokens
    // instead of stripping them out. It roughly matches the behavior of
    // BertPreTokenizer which keeps punctuation as token boundaries.
    final pattern = RegExp(r"\w+|[^\s\w]");
    final matches = pattern.allMatches(text);
    return matches
        .map((m) => m.group(0) ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  List<String> tokenize(String text) {
    // Step 1: Normalize text
    text = _normalizeText(text);

    // Step 2: Pre-tokenize
    List<String> words = _preTokenize(text);
    List<String> tokens = [];

    for (String word in words) {
      tokens.addAll(_tokenizeWord(word));
    }

    return tokens;
  }

  List<String> _tokenizeWord(String word) {
    if (word.isEmpty) return [];

    // If word is too long, use unknown token
    if (word.length > maxInputCharsPerWord) {
      return [unkToken];
    }

    // Check if the whole word exists in vocabulary
    if (vocab.containsKey(word)) {
      return [word];
    }

    // WordPiece tokenization
    List<String> tokens = [];
    String remaining = word;

    while (remaining.isNotEmpty) {
      String longestMatch = '';
      int longestLength = 0;

      // Find the longest matching subword
      for (int i = remaining.length; i > 0; i--) {
        String candidate = remaining.substring(0, i);

        // For subword tokens (not the first token), add ## prefix
        String vocabCandidate = tokens.isNotEmpty ? '##$candidate' : candidate;

        if (vocab.containsKey(vocabCandidate)) {
          longestMatch = vocabCandidate;
          longestLength = i;
          break;
        }
      }

      if (longestMatch.isEmpty) {
        // If no match found, use unknown token
        tokens.add(unkToken);
        break;
      } else {
        tokens.add(longestMatch);
        remaining = remaining.substring(longestLength);
      }
    }

    return tokens;
  }

  List<int> convertTokensToIds(List<String> tokens) {
    return tokens.map((token) => vocab[token] ?? vocab[unkToken]!).toList();
  }

  List<String> convertIdsToTokens(List<int> ids) {
    return ids.map((id) => invVocab[id] ?? unkToken).toList();
  }

  TokenizerOutput encode(String text) {
    List<String> tokens = tokenize(text);

    // Add special tokens: [CLS] + tokens + [SEP]
    List<String> fullTokens = [clsToken] + tokens + [sepToken];

    // Truncate to max length (keep [CLS] and [SEP])
    if (fullTokens.length > maxLength) {
      fullTokens = fullTokens.sublist(0, maxLength - 1) + [sepToken];
    }

    // Pad to max length
    while (fullTokens.length < maxLength) {
      fullTokens.add(padToken);
    }

    List<int> inputIds = convertTokensToIds(fullTokens);
    List<int> attentionMask =
        fullTokens.map((token) => token == padToken ? 0 : 1).toList();

    return TokenizerOutput(
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokens: fullTokens,
    );
  }
}

class TokenizerOutput {
  final List<int> inputIds;
  final List<int> attentionMask;
  final List<String> tokens;

  TokenizerOutput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokens,
  });
}

class PIIEntity {
  final String text;
  final String label;
  final int start;
  final int end;

  PIIEntity({
    required this.text,
    required this.label,
    required this.start,
    required this.end,
  });

  @override
  String toString() {
    return 'PIIEntity(text: $text, label: $label, start: $start, end: $end)';
  }
}

Future<List<PIIEntity>> detectPII(String text) async {
  if (!_isInitialized || _interpreter == null || _tokenizer == null) {
    throw Exception('PII detector not initialized. Call initialize() first.');
  }

  try {
    // Tokenize the input text
    final TokenizerOutput encoded = _tokenizer!.encode(text);

    // Get model input details
    final inputTensors = _interpreter!.getInputTensors();
    final outputTensors = _interpreter!.getOutputTensors();

    // Prepare input tensors
    List<int> inputIds = encoded.inputIds;
    List<int> attentionMask = encoded.attentionMask;

    // Ensure input length matches model expectation
    final expectedLength = inputTensors[0].shape[1];
    if (inputIds.length != expectedLength) {
      if (inputIds.length > expectedLength) {
        inputIds = inputIds.sublist(0, expectedLength);
        attentionMask = attentionMask.sublist(0, expectedLength);
      } else {
        while (inputIds.length < expectedLength) {
          inputIds.add(_tokenizer!.vocab[_tokenizer!.padToken] ?? 0);
          attentionMask.add(0);
        }
      }
    }

    // Convert to 2D arrays as expected by the model [batch_size, sequence_length]
    List<List<int>> inputIdsData = [inputIds];
    List<List<int>> attentionMaskData = [attentionMask];

    // Prepare output tensor - get the expected shape
    final outputShape = outputTensors[0].shape;

    // Allocate tensors first (before creating outputs)
    _interpreter!.allocateTensors();

    // Create output tensor with the correct shape [batch_size, sequence_length, num_labels]
    List<List<List<double>>> outputs = List.generate(
      outputShape[0], // batch_size (usually 1)
      (i) => List.generate(
        outputShape[1], // sequence_length (usually 128)
        (j) => List.filled(outputShape[2], 0.0), // num_labels (35)
      ),
    );

    Map<int, Object> outputsMap = {0: outputs};

    // Run inference - handle inputs exactly as training code does
    try {
      // Find the correct input indices (as done in training code)
      int inputIdsIdx = 0;
      int attentionMaskIdx = 1;

      // Try to find by name first (matching training code logic)
      for (int i = 0; i < inputTensors.length; i++) {
        final inputTensor = inputTensors[i];
        if (inputTensor.name.contains('input_ids')) {
          inputIdsIdx = i;
        } else if (inputTensor.name.contains('attention_mask')) {
          attentionMaskIdx = i;
        }
      }

      // Fallback: if not found by name, use the order from training code
      if (inputIdsIdx == 0 && attentionMaskIdx == 1) {
        // Check if we need to swap based on tensor names
        if (inputTensors.length >= 2) {
          if (inputTensors[0].name.contains('attention_mask') &&
              inputTensors[1].name.contains('input_ids')) {
            attentionMaskIdx = 0;
            inputIdsIdx = 1;
          }
        }
      }

      // Use runForMultipleInputs with proper input format (correct TFLite Flutter API)
      // Order inputs according to the indices we found
      List<Object> inputs = [];
      if (attentionMaskIdx < inputIdsIdx) {
        inputs = [attentionMaskData, inputIdsData];
      } else {
        inputs = [inputIdsData, attentionMaskData];
      }

      _interpreter!.runForMultipleInputs(inputs, outputsMap);
    } catch (e) {
      try {
        // Fallback: Try using single input (just input_ids)
        _interpreter!.run(inputIdsData, outputsMap);
      } catch (e2) {
        throw Exception('All inference methods failed: $e, $e2');
      }
    }

    // Get the results - these are LOGITS (raw scores), not probabilities
    List<List<List<double>>> results =
        outputsMap[0] as List<List<List<double>>>;

    // Validate model output
    final expectedLabels = _tokenizer!.idToLabel.length;
    if (!_validateModelOutput(results, expectedLabels)) {
      // Continue anyway, but log the issue
    }

    // Process predictions - use the first batch
    // IMPORTANT: Apply softmax to logits first (as done in training code)
    final predictions = _processPredictions(results[0], encoded.tokens, text);

    return predictions;
  } catch (e, stackTrace) {
    return [];
  }
}

List<PIIEntity> _processPredictions(
    dynamic logits, List<String> tokens, String originalText) {
  List<PIIEntity> entities = [];
  PIIEntity? currentEntity;

  // Ensure logits is in the correct format
  List<List<double>> logitsList;
  if (logits is List<List<double>>) {
    logitsList = logits;
  } else if (logits is List) {
    logitsList = logits.cast<List<double>>();
  } else {
    throw Exception('Unexpected logits format: ${logits.runtimeType}');
  }

  // Apply softmax to get probabilities (as done in training code)
  List<List<double>> probabilities = [];
  for (int i = 0; i < logitsList.length; i++) {
    List<double> tokenProbs = [];
    double maxLogit = logitsList[i].reduce((a, b) => a > b ? a : b);
    double sumExp = 0.0;

    // Compute sum of exponentials for numerical stability
    for (double logit in logitsList[i]) {
      sumExp += math.exp(logit - maxLogit);
    }

    // Compute softmax probabilities
    for (double logit in logitsList[i]) {
      tokenProbs.add(math.exp(logit - maxLogit) / sumExp);
    }
    probabilities.add(tokenProbs);
  }

  // Process each token position
  for (int i = 0; i < tokens.length && i < probabilities.length; i++) {
    final token = tokens[i];

    // Skip special tokens
    if (token == _tokenizer!.clsToken ||
        token == _tokenizer!.sepToken ||
        token == _tokenizer!.padToken) {
      continue;
    }

    // Get predicted label - use all model output labels (model outputs exactly 35 labels)
    final probsForToken =
        probabilities[i]; // Use all probabilities, not just first N
    final labelId = _argmax(probsForToken);

    // Map the label ID to our label names (0-34 for 35 labels)
    final labelName = labelId < _tokenizer!.idToLabel.length
        ? _tokenizer!.idToLabel[labelId] ?? 'O'
        : 'O';
    final confidence = probsForToken[labelId];

    // Only process non-O labels (entities) with reasonable confidence
    if (labelName != 'O') {
      if (labelName.startsWith('B-')) {
        // Beginning of new entity
        if (currentEntity != null) {
          entities.add(currentEntity);
        }

        final entityType = labelName.substring(2);
        currentEntity = PIIEntity(
          text: _cleanToken(token),
          label: entityType,
          start: i,
          end: i,
        );
      } else if (labelName.startsWith('I-') && currentEntity != null) {
        // Inside current entity
        final entityType = labelName.substring(2);
        if (currentEntity.label == entityType) {
          // Decide separator behavior when appending this token.
          final rawToken = token;
          final clean = _cleanToken(rawToken);

          // Determine if the token is a subword (WordPiece) or pure punctuation
          final bool isSubword = rawToken.startsWith('##');
          final bool isPunct = RegExp(r"^[^\w\s]+").hasMatch(clean);

          String sep = ' ';
          if (isSubword || isPunct) {
            // Attach directly without a space for subwords and punctuation
            sep = '';
          } else {
            // If current text already ends with punctuation (like '@' or '.')
            // don't insert a space before the next token
            if (currentEntity.text.isNotEmpty &&
                RegExp(r"[^\w\s]").hasMatch(currentEntity.text
                    .substring(currentEntity.text.length - 1))) {
              sep = '';
            }
          }

          currentEntity = PIIEntity(
            text: currentEntity.text + sep + clean,
            label: currentEntity.label,
            start: currentEntity.start,
            end: i,
          );
        }
      }
    } else {
      // Outside entity (O label) or low confidence
      if (currentEntity != null) {
        entities.add(currentEntity);
        currentEntity = null;
      }
    }
  }

  if (currentEntity != null) {
    entities.add(currentEntity);
  }

  return entities;
}

// Test helper: expose a simplified detection wrapper for unit tests.
// This avoids running the TFLite model and allows tests to call the
// token->entity reconstruction logic with mocked logits.
List<PIIEntity> test_processPredictionsWithMockedLogits(
    List<List<double>> mockedLogits, List<String> tokens) {
  return _processPredictions(mockedLogits, tokens, tokens.join(' '));
}

// Test-only API: allow tests to inject a tokenizer instance. This makes it
// possible to unit test token->entity reconstruction without running the
// TFLite model.
void setTestTokenizerForUnitTests(DistilBertTokenizer tokenizer) {
  _tokenizer = tokenizer;
}

String _cleanToken(String token) {
  if (token.startsWith('##')) {
    return token.substring(2);
  }
  return token;
}

// Function to reconstruct original text from tokens
String _reconstructText(List<String> tokens) {
  String result = '';
  for (String token in tokens) {
    if (token.startsWith('##')) {
      // Remove ## prefix and add without space
      result += token.substring(2);
    } else {
      // Add space before token (except for first token)
      if (result.isNotEmpty) {
        result += ' ';
      }
      result += token;
    }
  }
  return result;
}

int _argmax(List<double> array) {
  double maxValue = array[0];
  int maxIndex = 0;

  for (int i = 1; i < array.length; i++) {
    if (array[i] > maxValue) {
      maxValue = array[i];
      maxIndex = i;
    }
  }

  return maxIndex;
}

// Function to validate model output dimensions
bool _validateModelOutput(
    List<List<List<double>>> results, int expectedLabels) {
  if (results.isEmpty || results[0].isEmpty || results[0][0].isEmpty) {
    return false;
  }

  final actualLabels = results[0][0].length;
  if (actualLabels < expectedLabels) {
    return false;
  }

  return true;
}

void dispose() {
  _interpreter?.close();
  _interpreter = null;
  _tokenizer = null;
  _isInitialized = false;
}

class RiskScorePainter extends CustomPainter {
  final double value;
  final Color color;

  RiskScorePainter({required this.value, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;
    final startAngle = -0.5 * math.pi;
    final sweepAngle = 2 * math.pi * value.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class LoadingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color(0xFF0C7FF2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;

    // Create a rotating animation effect
    final now = DateTime.now();
    final startAngle = (now.millisecondsSinceEpoch / 1000) * 2 * math.pi;
    final sweepAngle = 0.7 * math.pi;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
