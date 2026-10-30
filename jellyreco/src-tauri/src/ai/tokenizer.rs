//! BERT "uncased" WordPiece tokenizer (what bge-small-en-v1.5 uses): lower-case,
//! accents stripped, punctuation and CJK characters split off, then greedy longest-match
//! word pieces from `vocab.txt`.

use std::collections::HashMap;
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

pub struct WordPiece {
    vocab: HashMap<String, i64>,
    unk: i64,
    cls: i64,
    sep: i64,
    pad: i64,
}

pub struct Encoded {
    pub input_ids: Vec<i64>,
    pub attention_mask: Vec<i64>,
    pub token_type_ids: Vec<i64>,
}

impl WordPiece {
    pub fn from_vocab(text: &str) -> Result<Self, String> {
        let vocab: HashMap<String, i64> = text
            .lines()
            .enumerate()
            .map(|(i, line)| (line.trim_end_matches('\r').to_string(), i as i64))
            .collect();
        let id = |t: &str| vocab.get(t).copied().ok_or_else(|| format!("vocab.txt has no {t}"));
        Ok(Self { unk: id("[UNK]")?, cls: id("[CLS]")?, sep: id("[SEP]")?, pad: id("[PAD]")?, vocab })
    }

    /// `[CLS] tokens… [SEP]`, cut or padded to exactly `len` (the model's fixed shape).
    pub fn encode(&self, text: &str, len: usize) -> Encoded {
        let mut ids = vec![self.cls];
        'words: for word in basic_tokens(text) {
            for piece in self.word_pieces(&word) {
                if ids.len() >= len - 1 {
                    break 'words;
                }
                ids.push(piece);
            }
        }
        ids.push(self.sep);
        let used = ids.len();
        ids.resize(len, self.pad);
        let mut mask = vec![1i64; used];
        mask.resize(len, 0);
        Encoded { input_ids: ids, attention_mask: mask, token_type_ids: vec![0; len] }
    }

    fn word_pieces(&self, word: &str) -> Vec<i64> {
        let chars: Vec<char> = word.chars().collect();
        if chars.len() > 100 {
            return vec![self.unk];
        }
        let mut out = Vec::new();
        let mut start = 0;
        while start < chars.len() {
            let mut end = chars.len();
            let mut found = None;
            while start < end {
                let mut piece: String = chars[start..end].iter().collect();
                if start > 0 {
                    piece.insert_str(0, "##");
                }
                if let Some(&id) = self.vocab.get(&piece) {
                    found = Some(id);
                    break;
                }
                end -= 1;
            }
            match found {
                Some(id) => {
                    out.push(id);
                    start = end;
                }
                None => return vec![self.unk],
            }
        }
        out
    }
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0x20000..=0x2A6DF | 0x2A700..=0x2B73F |
        0x2B740..=0x2B81F | 0x2B820..=0x2CEAF | 0xF900..=0xFAFF | 0x2F800..=0x2FA1F)
}

fn is_punctuation(c: char) -> bool {
    if c.is_ascii() {
        return c.is_ascii_punctuation();
    }
    // General punctuation, CJK symbols and punctuation, full-width forms, other common marks.
    matches!(c as u32, 0x2000..=0x206F | 0x3000..=0x303F | 0xFF01..=0xFF0F | 0xFF1A..=0xFF20 |
        0xFF3B..=0xFF40 | 0xFF5B..=0xFF65 | 0x00A1..=0x00BF | 0x2E00..=0x2E7F)
        && !c.is_alphanumeric()
}

/// Clean, lower-case, strip accents, split on spaces, punctuation and CJK characters.
fn basic_tokens(text: &str) -> Vec<String> {
    let mut spaced = String::with_capacity(text.len() + 16);
    for c in text.chars() {
        if c == '\0' || c == '\u{FFFD}' || (c.is_control() && !c.is_whitespace()) {
            continue;
        }
        if is_cjk(c) {
            spaced.push(' ');
            spaced.push(c);
            spaced.push(' ');
        } else if c.is_whitespace() {
            spaced.push(' ');
        } else {
            spaced.push(c);
        }
    }
    let mut out = Vec::new();
    for raw in spaced.split_whitespace() {
        let lowered: String = raw.to_lowercase().nfd().filter(|c| !is_combining_mark(*c)).collect();
        let mut current = String::new();
        for c in lowered.chars() {
            if is_punctuation(c) {
                if !current.is_empty() {
                    out.push(std::mem::take(&mut current));
                }
                out.push(c.to_string());
            } else {
                current.push(c);
            }
        }
        if !current.is_empty() {
            out.push(current);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiny() -> WordPiece {
        let vocab = "[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\nworld\n,\n!\nun\n##aff\n##able\ncafe\n日\n本";
        WordPiece::from_vocab(vocab).unwrap()
    }

    #[test]
    fn splits_words_punctuation_and_pieces() {
        let t = tiny();
        let e = t.encode("Hello, WORLD! unaffable Café 日本", 16);
        // [CLS] hello , world ! un ##aff ##able cafe 日 本 [SEP]
        assert_eq!(&e.input_ids[..12], &[2, 4, 6, 5, 7, 8, 9, 10, 11, 12, 13, 3]);
        assert_eq!(e.attention_mask.iter().sum::<i64>(), 12);
        assert_eq!(e.input_ids.len(), 16);
        assert_eq!(e.input_ids[12..], [0, 0, 0, 0]);
    }

    #[test]
    fn unknown_word_and_truncation() {
        let t = tiny();
        let e = t.encode("zzz hello hello hello hello", 4);
        assert_eq!(e.input_ids, vec![2, 1, 4, 3]);
        assert_eq!(e.attention_mask, vec![1, 1, 1, 1]);
    }
}
