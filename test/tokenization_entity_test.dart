import 'package:flutter_test/flutter_test.dart';
import 'package:priv_guard/screens/scan_analysis_screen.dart';

void main() {
  test('email tokenization and reconstruction preserves punctuation', () async {
    // Prepare a minimal vocab (lines) for tokenizer. The tokenizer only needs
    // some example tokens; the actual indices in vocab are not used for
    // reconstructing the entity text in our test.
    final vocabText = '''[PAD]
[CLS]
[SEP]
[UNK]
[MASK]
shaurya
gmail
com
@
.
''';

    final tokenizer = DistilBertTokenizer();
    await tokenizer.loadVocab(vocabText);

    // Inject tokenizer into library for testing
    setTestTokenizerForUnitTests(tokenizer);

    // Simulate tokenized output including special tokens
    final tokens = ['[CLS]', 'shaurya', '@', 'gmail', '.', 'com', '[SEP]'];

    // Determine label IDs for B-EMAIL and I-EMAIL
    final bEmailId = tokenizer.labelToId['B-EMAIL']!;
    final iEmailId = tokenizer.labelToId['I-EMAIL']!;

    final numLabels = tokenizer.idToLabel.length;

    // Build mocked logits: for each token position produce a logits vector
    // where the argmax corresponds to the appropriate label.
    List<List<double>> mockedLogits = [];

    for (int i = 0; i < tokens.length; i++) {
      // Default low score for all labels
      List<double> vec = List.filled(numLabels, -10.0);

      if (i == 1) {
        // 'shaurya' -> B-EMAIL
        vec[bEmailId] = 10.0;
      } else if (i >= 2 && i <= 5) {
        // '@', 'gmail', '.', 'com' -> I-EMAIL (continuation)
        vec[iEmailId] = 10.0;
      } else {
        // Others -> O (which is id 0)
        vec[0] = 10.0;
      }

      mockedLogits.add(vec);
    }

    // Call the test helper to process mocked logits and tokens
    final entities =
        test_processPredictionsWithMockedLogits(mockedLogits, tokens);

    expect(entities.length, 1);
    expect(entities[0].label, 'EMAIL');
    // The tokenizer normalizes to lowercase (doLowerCase true), so expect lowercase
    expect(entities[0].text, 'shaurya@gmail.com');
  });
}
