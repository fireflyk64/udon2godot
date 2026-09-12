//! C# lexer for the UdonSharp subset.
//!
//! Handles: identifiers (incl. `@verbatim`), keywords, integer/real literals with
//! suffixes, char/string/verbatim/interpolated strings, comments (`//`, `/* */`,
//! `///` doc comments are attached to the next token), and preprocessor lines.
//! `#region`/`#endregion`/`#pragma` are ignored. `#if`/`#else`/`#endif` are
//! evaluated with a fixed symbol set (`UDON`, `UDONSHARP`, `COMPILER_UDONSHARP`
//! defined; `UNITY_EDITOR` undefined), so editor-only blocks are dropped.

use crate::diag::{ParseError, Span};
use crate::token::{InterpPart, Kw, Lit, Tok, Token, P};

pub struct Lexer<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
    line: u32,
    col: u32,
    pending_doc: Option<String>,
    /// Preprocessor conditional stack: (this branch active, any branch taken so far, parent active)
    pp_stack: Vec<(bool, bool, bool)>,
    defined: Vec<&'static str>,
}

fn is_ident_start(c: char) -> bool {
    c == '_' || c.is_alphabetic()
}

fn is_ident_continue(c: char) -> bool {
    c == '_' || c.is_alphanumeric()
}

impl<'a> Lexer<'a> {
    /// Up to `n` bytes of the remaining source, cut back to a UTF-8 character boundary.
    fn peek_str(&self, n: usize) -> &'a str {
        let mut end = std::cmp::min(self.pos + n, self.src.len());
        while !self.src.is_char_boundary(end) {
            end -= 1;
        }
        &self.src[self.pos..end]
    }

    pub fn new(src: &'a str) -> Self {
        // Skip UTF-8 BOM.
        let src = src.strip_prefix('\u{feff}').unwrap_or(src);
        Self {
            src,
            bytes: src.as_bytes(),
            pos: 0,
            line: 1,
            col: 1,
            pending_doc: None,
            pp_stack: Vec::new(),
            defined: vec!["UDON", "UDONSHARP", "COMPILER_UDONSHARP", "VRC_SDK_VRCSDK3"],
        }
    }

    pub fn tokenize(mut self) -> Result<Vec<Token>, ParseError> {
        let mut out = Vec::new();
        loop {
            let t = self.next_token()?;
            let eof = t.tok == Tok::Eof;
            out.push(t);
            if eof {
                break;
            }
        }
        Ok(out)
    }

    fn span(&self) -> Span {
        Span::new(self.line, self.col)
    }

    fn peek_char(&self) -> Option<char> {
        self.src[self.pos..].chars().next()
    }

    fn peek_char_at(&self, n: usize) -> Option<char> {
        self.src[self.pos..].chars().nth(n)
    }

    fn peek_byte(&self, n: usize) -> u8 {
        *self.bytes.get(self.pos + n).unwrap_or(&0)
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek_char()?;
        self.pos += c.len_utf8();
        if c == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(c)
    }

    fn starts_with(&self, s: &str) -> bool {
        self.src[self.pos..].starts_with(s)
    }

    fn pp_active(&self) -> bool {
        self.pp_stack.iter().all(|(active, _, _)| *active)
    }

    fn err<T>(&self, msg: impl Into<String>) -> Result<T, ParseError> {
        Err(ParseError { span: self.span(), message: msg.into() })
    }

    /// Skip whitespace, comments and preprocessor directives. Collects `///` docs.
    fn skip_trivia(&mut self) -> Result<(), ParseError> {
        loop {
            // Inside an inactive preprocessor branch, skip whole lines until a directive.
            if !self.pp_active() {
                // consume until next line start with '#'
                loop {
                    // skip to line start
                    let mut at_line_start = self.pos == 0 || self.bytes.get(self.pos - 1) == Some(&b'\n');
                    // skip leading whitespace
                    while let Some(c) = self.peek_char() {
                        if c == ' ' || c == '\t' || c == '\r' {
                            self.bump();
                        } else {
                            break;
                        }
                    }
                    if at_line_start && self.peek_char() == Some('#') {
                        break;
                    }
                    // consume the rest of line
                    while let Some(c) = self.peek_char() {
                        self.bump();
                        if c == '\n' {
                            break;
                        }
                    }
                    if self.pos >= self.src.len() {
                        return Ok(());
                    }
                    at_line_start = true;
                    let _ = at_line_start;
                }
                self.handle_directive()?;
                continue;
            }
            match self.peek_char() {
                None => return Ok(()),
                Some(c) if c.is_whitespace() => {
                    self.bump();
                }
                Some('/') if self.peek_byte(1) == b'/' => {
                    let is_doc = self.peek_byte(2) == b'/' && self.peek_byte(3) != b'/';
                    self.bump();
                    self.bump();
                    if is_doc {
                        self.bump();
                    }
                    let start = self.pos;
                    while let Some(c) = self.peek_char() {
                        if c == '\n' {
                            break;
                        }
                        self.bump();
                    }
                    if is_doc {
                        let text = self.src[start..self.pos].trim().to_string();
                        match &mut self.pending_doc {
                            Some(d) => {
                                d.push('\n');
                                d.push_str(&text);
                            }
                            None => self.pending_doc = Some(text),
                        }
                    }
                }
                Some('/') if self.peek_byte(1) == b'*' => {
                    self.bump();
                    self.bump();
                    loop {
                        match self.peek_char() {
                            None => return self.err("unterminated block comment"),
                            Some('*') if self.peek_byte(1) == b'/' => {
                                self.bump();
                                self.bump();
                                break;
                            }
                            _ => {
                                self.bump();
                            }
                        }
                    }
                }
                Some('#') => {
                    // Only a directive if at line start (ignoring whitespace).
                    let mut i = self.pos;
                    let mut at_line_start = true;
                    while i > 0 {
                        i -= 1;
                        let b = self.bytes[i];
                        if b == b'\n' {
                            break;
                        }
                        if b != b' ' && b != b'\t' && b != b'\r' {
                            at_line_start = false;
                            break;
                        }
                    }
                    if !at_line_start {
                        return Ok(());
                    }
                    self.handle_directive()?;
                }
                _ => return Ok(()),
            }
        }
    }

    fn handle_directive(&mut self) -> Result<(), ParseError> {
        // at '#'
        self.bump();
        let start = self.pos;
        while let Some(c) = self.peek_char() {
            if c == '\n' {
                break;
            }
            self.bump();
        }
        let line = self.src[start..self.pos].trim().to_string();
        let (name, rest) = match line.find(char::is_whitespace) {
            Some(i) => (&line[..i], line[i..].trim()),
            None => (line.as_str(), ""),
        };
        match name {
            "if" => {
                let parent = self.pp_active();
                let v = self.eval_pp_expr(rest);
                self.pp_stack.push((parent && v, v, parent));
            }
            "elif" => {
                if let Some((_, taken, parent)) = self.pp_stack.pop() {
                    let v = self.eval_pp_expr(rest);
                    let active = parent && !taken && v;
                    self.pp_stack.push((active, taken || v, parent));
                }
            }
            "else" => {
                if let Some((_, taken, parent)) = self.pp_stack.pop() {
                    self.pp_stack.push((parent && !taken, true, parent));
                }
            }
            "endif" => {
                self.pp_stack.pop();
            }
            "define" => {
                let sym: &'static str = Box::leak(rest.to_string().into_boxed_str());
                self.defined.push(sym);
            }
            "undef" => {
                self.defined.retain(|s| *s != rest);
            }
            // region, endregion, pragma, warning, error, line, nullable: ignored
            _ => {}
        }
        Ok(())
    }

    /// Minimal preprocessor expression evaluator: identifiers, `!`, `&&`, `||`, parens, true/false.
    fn eval_pp_expr(&self, s: &str) -> bool {
        let toks: Vec<String> = {
            let mut v = Vec::new();
            let cs: Vec<char> = s.chars().collect();
            let mut i = 0;
            while i < cs.len() {
                let c = cs[i];
                if c.is_whitespace() {
                    i += 1;
                } else if is_ident_start(c) {
                    let st = i;
                    while i < cs.len() && is_ident_continue(cs[i]) {
                        i += 1;
                    }
                    v.push(cs[st..i].iter().collect());
                } else if c == '&' && i + 1 < cs.len() && cs[i + 1] == '&' {
                    v.push("&&".into());
                    i += 2;
                } else if c == '|' && i + 1 < cs.len() && cs[i + 1] == '|' {
                    v.push("||".into());
                    i += 2;
                } else if c == '=' && i + 1 < cs.len() && cs[i + 1] == '=' {
                    v.push("==".into());
                    i += 2;
                } else if c == '!' && i + 1 < cs.len() && cs[i + 1] == '=' {
                    v.push("!=".into());
                    i += 2;
                } else {
                    v.push(c.to_string());
                    i += 1;
                }
            }
            v
        };
        let mut pos = 0;
        let r = self.pp_or(&toks, &mut pos);
        r
    }

    fn pp_or(&self, t: &[String], pos: &mut usize) -> bool {
        let mut v = self.pp_and(t, pos);
        while *pos < t.len() && t[*pos] == "||" {
            *pos += 1;
            let r = self.pp_and(t, pos);
            v = v || r;
        }
        v
    }

    fn pp_and(&self, t: &[String], pos: &mut usize) -> bool {
        let mut v = self.pp_eq(t, pos);
        while *pos < t.len() && t[*pos] == "&&" {
            *pos += 1;
            let r = self.pp_eq(t, pos);
            v = v && r;
        }
        v
    }

    fn pp_eq(&self, t: &[String], pos: &mut usize) -> bool {
        let mut v = self.pp_unary(t, pos);
        while *pos < t.len() && (t[*pos] == "==" || t[*pos] == "!=") {
            let op = t[*pos].clone();
            *pos += 1;
            let r = self.pp_unary(t, pos);
            v = if op == "==" { v == r } else { v != r };
        }
        v
    }

    fn pp_unary(&self, t: &[String], pos: &mut usize) -> bool {
        if *pos >= t.len() {
            return false;
        }
        if t[*pos] == "!" {
            *pos += 1;
            return !self.pp_unary(t, pos);
        }
        if t[*pos] == "(" {
            *pos += 1;
            let v = self.pp_or(t, pos);
            if *pos < t.len() && t[*pos] == ")" {
                *pos += 1;
            }
            return v;
        }
        let name = &t[*pos];
        *pos += 1;
        match name.as_str() {
            "true" => true,
            "false" => false,
            n => self.defined.iter().any(|d| *d == n),
        }
    }

    fn next_token(&mut self) -> Result<Token, ParseError> {
        self.skip_trivia()?;
        let doc = self.pending_doc.take();
        let span = self.span();
        let offset = self.pos;
        let tok = match self.peek_char() {
            None => Tok::Eof,
            Some(c) => self.lex_token(c)?,
        };
        Ok(Token { tok, span, offset, len: self.pos - offset, doc })
    }

    fn lex_token(&mut self, c: char) -> Result<Tok, ParseError> {
        // Interpolated / verbatim strings
        if c == '$' && self.peek_byte(1) == b'"' {
            self.bump();
            self.bump();
            return self.lex_interpolated(false);
        }
        if c == '$' && self.peek_byte(1) == b'@' && self.peek_byte(2) == b'"' {
            self.bump();
            self.bump();
            self.bump();
            return self.lex_interpolated(true);
        }
        if c == '@' && self.peek_byte(1) == b'$' && self.peek_byte(2) == b'"' {
            self.bump();
            self.bump();
            self.bump();
            return self.lex_interpolated(true);
        }
        if c == '@' && self.peek_byte(1) == b'"' {
            self.bump();
            self.bump();
            return Ok(Tok::Lit(Lit::Str(self.lex_verbatim_body()?)));
        }
        if c == '@' {
            // verbatim identifier
            self.bump();
            let id = self.lex_ident_raw();
            return Ok(Tok::Ident(id));
        }
        if is_ident_start(c) {
            let id = self.lex_ident_raw();
            return Ok(match Kw::from_str(&id) {
                Some(Kw::True) => Tok::Lit(Lit::Bool(true)),
                Some(Kw::False) => Tok::Lit(Lit::Bool(false)),
                Some(Kw::Null) => Tok::Lit(Lit::Null),
                Some(k) => Tok::Keyword(k),
                None => Tok::Ident(id),
            });
        }
        if c.is_ascii_digit() || (c == '.' && self.peek_byte(1).is_ascii_digit()) {
            return self.lex_number();
        }
        if c == '"' {
            self.bump();
            return Ok(Tok::Lit(Lit::Str(self.lex_string_body()?)));
        }
        if c == '\'' {
            self.bump();
            let ch = match self.peek_char() {
                Some('\\') => {
                    self.bump();
                    self.lex_escape()?
                }
                Some(ch) => {
                    self.bump();
                    ch
                }
                None => return self.err("unterminated char literal"),
            };
            if self.peek_char() != Some('\'') {
                return self.err("expected closing ' in char literal");
            }
            self.bump();
            return Ok(Tok::Lit(Lit::Char(ch)));
        }
        // Punctuation
        let three = self.peek_str(3);
        let p3 = match three {
            "<<=" => Some(P::LtLtEq),
            "??=" => Some(P::QuestionQuestionEq),
            _ => None,
        };
        if let Some(p) = p3 {
            for _ in 0..3 {
                self.bump();
            }
            return Ok(Tok::Punct(p));
        }
        let two = self.peek_str(2);
        let p2 = match two {
            "?." => Some(P::QuestionDot),
            "??" => Some(P::QuestionQuestion),
            "::" => Some(P::ColonColon),
            "=>" => Some(P::Arrow),
            "!=" => Some(P::BangEq),
            "==" => Some(P::EqEq),
            "++" => Some(P::PlusPlus),
            "+=" => Some(P::PlusEq),
            "--" => Some(P::MinusMinus),
            "-=" => Some(P::MinusEq),
            "*=" => Some(P::StarEq),
            "/=" => Some(P::SlashEq),
            "%=" => Some(P::PercentEq),
            "&&" => Some(P::AmpAmp),
            "&=" => Some(P::AmpEq),
            "||" => Some(P::PipePipe),
            "|=" => Some(P::PipeEq),
            "^=" => Some(P::CaretEq),
            "<=" => Some(P::LtEq),
            "<<" => Some(P::LtLt),
            ">=" => Some(P::GtEq),
            _ => None,
        };
        if let Some(p) = p2 {
            // `?.` followed by a digit is `?` then `.5` — not relevant in practice.
            self.bump();
            self.bump();
            return Ok(Tok::Punct(p));
        }
        let p1 = match c {
            '(' => P::LParen,
            ')' => P::RParen,
            '{' => P::LBrace,
            '}' => P::RBrace,
            '[' => P::LBracket,
            ']' => P::RBracket,
            ';' => P::Semi,
            ',' => P::Comma,
            '.' => P::Dot,
            '?' => P::Question,
            ':' => P::Colon,
            '~' => P::Tilde,
            '!' => P::Bang,
            '=' => P::Eq,
            '+' => P::Plus,
            '-' => P::Minus,
            '*' => P::Star,
            '/' => P::Slash,
            '%' => P::Percent,
            '&' => P::Amp,
            '|' => P::Pipe,
            '^' => P::Caret,
            '<' => P::Lt,
            '>' => P::Gt,
            '#' => P::Hash,
            other => return self.err(format!("unexpected character `{}`", other)),
        };
        self.bump();
        Ok(Tok::Punct(p1))
    }

    fn lex_ident_raw(&mut self) -> String {
        let start = self.pos;
        while let Some(c) = self.peek_char() {
            if is_ident_continue(c) {
                self.bump();
            } else {
                break;
            }
        }
        self.src[start..self.pos].to_string()
    }

    fn lex_number(&mut self) -> Result<Tok, ParseError> {
        let start = self.pos;
        // Hex / binary
        if self.peek_char() == Some('0') && matches!(self.peek_byte(1), b'x' | b'X') {
            self.bump();
            self.bump();
            let ds = self.pos;
            while let Some(c) = self.peek_char() {
                if c.is_ascii_hexdigit() || c == '_' {
                    self.bump();
                } else {
                    break;
                }
            }
            let digits: String = self.src[ds..self.pos].chars().filter(|c| *c != '_').collect();
            let v = u64::from_str_radix(&digits, 16).map_err(|_| ParseError { span: self.span(), message: "bad hex literal".into() })?;
            return Ok(Tok::Lit(self.int_suffix(v)));
        }
        if self.peek_char() == Some('0') && matches!(self.peek_byte(1), b'b' | b'B') {
            self.bump();
            self.bump();
            let ds = self.pos;
            while let Some(c) = self.peek_char() {
                if c == '0' || c == '1' || c == '_' {
                    self.bump();
                } else {
                    break;
                }
            }
            let digits: String = self.src[ds..self.pos].chars().filter(|c| *c != '_').collect();
            let v = u64::from_str_radix(&digits, 2).map_err(|_| ParseError { span: self.span(), message: "bad binary literal".into() })?;
            return Ok(Tok::Lit(self.int_suffix(v)));
        }
        let mut is_real = false;
        while let Some(c) = self.peek_char() {
            if c.is_ascii_digit() || c == '_' {
                self.bump();
            } else {
                break;
            }
        }
        if self.peek_char() == Some('.') && self.peek_byte(1).is_ascii_digit() {
            is_real = true;
            self.bump();
            while let Some(c) = self.peek_char() {
                if c.is_ascii_digit() || c == '_' {
                    self.bump();
                } else {
                    break;
                }
            }
        }
        if matches!(self.peek_char(), Some('e') | Some('E')) {
            let save = (self.pos, self.line, self.col);
            self.bump();
            if matches!(self.peek_char(), Some('+') | Some('-')) {
                self.bump();
            }
            if self.peek_char().map_or(false, |c| c.is_ascii_digit()) {
                is_real = true;
                while let Some(c) = self.peek_char() {
                    if c.is_ascii_digit() {
                        self.bump();
                    } else {
                        break;
                    }
                }
            } else {
                self.pos = save.0;
                self.line = save.1;
                self.col = save.2;
            }
        }
        let text: String = self.src[start..self.pos].chars().filter(|c| *c != '_').collect();
        // suffix
        match self.peek_char() {
            Some('f') | Some('F') => {
                self.bump();
                let v: f64 = text.parse().map_err(|_| ParseError { span: self.span(), message: "bad float literal".into() })?;
                Ok(Tok::Lit(Lit::Float(v)))
            }
            Some('d') | Some('D') => {
                self.bump();
                let v: f64 = text.parse().map_err(|_| ParseError { span: self.span(), message: "bad double literal".into() })?;
                Ok(Tok::Lit(Lit::Double(v)))
            }
            Some('m') | Some('M') => {
                self.bump();
                let v: f64 = text.parse().map_err(|_| ParseError { span: self.span(), message: "bad decimal literal".into() })?;
                Ok(Tok::Lit(Lit::Double(v)))
            }
            _ if is_real => {
                let v: f64 = text.parse().map_err(|_| ParseError { span: self.span(), message: "bad real literal".into() })?;
                Ok(Tok::Lit(Lit::Double(v)))
            }
            _ => {
                let v: u64 = text.parse().map_err(|_| ParseError { span: self.span(), message: "bad integer literal".into() })?;
                Ok(Tok::Lit(self.int_suffix(v)))
            }
        }
    }

    fn int_suffix(&mut self, v: u64) -> Lit {
        let mut is_u = false;
        let mut is_l = false;
        for _ in 0..2 {
            match self.peek_char() {
                Some('u') | Some('U') if !is_u => {
                    self.bump();
                    is_u = true;
                }
                Some('l') | Some('L') if !is_l => {
                    self.bump();
                    is_l = true;
                }
                _ => break,
            }
        }
        match (is_u, is_l) {
            (true, true) => Lit::ULong(v),
            (true, false) => Lit::UInt(v),
            (false, true) => Lit::Long(v as i64),
            (false, false) => {
                if v > i32::MAX as u64 {
                    if v <= u32::MAX as u64 {
                        Lit::UInt(v)
                    } else {
                        Lit::Long(v as i64)
                    }
                } else {
                    Lit::Int(v as i64)
                }
            }
        }
    }

    fn lex_escape(&mut self) -> Result<char, ParseError> {
        let c = match self.bump() {
            Some(c) => c,
            None => return self.err("unterminated escape"),
        };
        Ok(match c {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => '\0',
            'a' => '\x07',
            'b' => '\x08',
            'f' => '\x0c',
            'v' => '\x0b',
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            'u' => {
                let mut v = 0u32;
                for _ in 0..4 {
                    let d = self.bump().and_then(|c| c.to_digit(16));
                    match d {
                        Some(d) => v = v * 16 + d,
                        None => return self.err("bad \\u escape"),
                    }
                }
                char::from_u32(v).unwrap_or('\u{fffd}')
            }
            'x' => {
                let mut v = 0u32;
                let mut n = 0;
                while n < 4 {
                    match self.peek_char().and_then(|c| c.to_digit(16)) {
                        Some(d) => {
                            self.bump();
                            v = v * 16 + d;
                            n += 1;
                        }
                        None => break,
                    }
                }
                char::from_u32(v).unwrap_or('\u{fffd}')
            }
            other => other,
        })
    }

    fn lex_string_body(&mut self) -> Result<String, ParseError> {
        let mut s = String::new();
        loop {
            match self.peek_char() {
                None | Some('\n') => return self.err("unterminated string literal"),
                Some('"') => {
                    self.bump();
                    return Ok(s);
                }
                Some('\\') => {
                    self.bump();
                    s.push(self.lex_escape()?);
                }
                Some(c) => {
                    self.bump();
                    s.push(c);
                }
            }
        }
    }

    fn lex_verbatim_body(&mut self) -> Result<String, ParseError> {
        let mut s = String::new();
        loop {
            match self.peek_char() {
                None => return self.err("unterminated verbatim string"),
                Some('"') => {
                    self.bump();
                    if self.peek_char() == Some('"') {
                        self.bump();
                        s.push('"');
                    } else {
                        return Ok(s);
                    }
                }
                Some(c) => {
                    self.bump();
                    s.push(c);
                }
            }
        }
    }

    fn lex_interpolated(&mut self, verbatim: bool) -> Result<Tok, ParseError> {
        let mut parts = Vec::new();
        let mut text = String::new();
        loop {
            match self.peek_char() {
                None => return self.err("unterminated interpolated string"),
                Some('"') => {
                    self.bump();
                    if verbatim && self.peek_char() == Some('"') {
                        self.bump();
                        text.push('"');
                        continue;
                    }
                    if !text.is_empty() {
                        parts.push(InterpPart::Text(std::mem::take(&mut text)));
                    }
                    return Ok(Tok::InterpStr(parts));
                }
                Some('\\') if !verbatim => {
                    self.bump();
                    text.push(self.lex_escape()?);
                }
                Some('{') => {
                    self.bump();
                    if self.peek_char() == Some('{') {
                        self.bump();
                        text.push('{');
                        continue;
                    }
                    if !text.is_empty() {
                        parts.push(InterpPart::Text(std::mem::take(&mut text)));
                    }
                    let span = self.span();
                    // Read until matching '}' at depth 0, tracking nested parens/brackets and strings.
                    let start = self.pos;
                    let mut depth = 0i32;
                    let mut in_str = false;
                    let mut expr_end = None;
                    let mut fmt_start = None;
                    loop {
                        let c = match self.peek_char() {
                            Some(c) => c,
                            None => return self.err("unterminated interpolation"),
                        };
                        if in_str {
                            if c == '\\' {
                                self.bump();
                                self.bump();
                                continue;
                            }
                            if c == '"' {
                                in_str = false;
                            }
                            self.bump();
                            continue;
                        }
                        match c {
                            '"' => in_str = true,
                            '(' | '[' => depth += 1,
                            ')' | ']' => depth -= 1,
                            ':' if depth == 0 && fmt_start.is_none() => {
                                expr_end = Some(self.pos);
                                self.bump();
                                fmt_start = Some(self.pos);
                                continue;
                            }
                            '}' if depth == 0 => break,
                            _ => {}
                        }
                        self.bump();
                    }
                    let end = self.pos;
                    self.bump(); // '}'
                    let (source, format) = match (expr_end, fmt_start) {
                        (Some(e), Some(f)) => (self.src[start..e].to_string(), Some(self.src[f..end].to_string())),
                        _ => (self.src[start..end].to_string(), None),
                    };
                    // Strip alignment component `,N` from expression (rare).
                    parts.push(InterpPart::Expr { source, format, span });
                }
                Some('}') => {
                    self.bump();
                    if self.peek_char() == Some('}') {
                        self.bump();
                    }
                    text.push('}');
                }
                Some(c) => {
                    self.bump();
                    text.push(c);
                }
            }
        }
    }
}

/// Convenience: tokenize a string.
pub fn tokenize(src: &str) -> Result<Vec<Token>, ParseError> {
    Lexer::new(src).tokenize()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lex_basic() {
        let toks = tokenize("int x = 3; float y = 2.5f; var s = \"hi\\n\"; // c\n x++;").unwrap();
        let kinds: Vec<String> = toks.iter().map(|t| t.describe()).collect();
        assert!(kinds[0].contains("int"));
        assert_eq!(toks[3].tok, Tok::Lit(Lit::Int(3)));
        assert_eq!(toks[8].tok, Tok::Lit(Lit::Float(2.5)));
        assert_eq!(toks[13].tok, Tok::Lit(Lit::Str("hi\n".into())));
    }

    #[test]
    fn lex_preprocessor() {
        let toks = tokenize("#if UNITY_EDITOR\nint a;\n#else\nint b;\n#endif\nint c;").unwrap();
        let idents: Vec<String> = toks
            .iter()
            .filter_map(|t| if let Tok::Ident(s) = &t.tok { Some(s.clone()) } else { None })
            .collect();
        assert_eq!(idents, vec!["b", "c"]);
    }

    #[test]
    fn lex_interp() {
        let toks = tokenize("$\"a{x + 1:F2}b\"").unwrap();
        match &toks[0].tok {
            Tok::InterpStr(parts) => {
                assert_eq!(parts.len(), 3);
                match &parts[1] {
                    InterpPart::Expr { source, format, .. } => {
                        assert_eq!(source, "x + 1");
                        assert_eq!(format.as_deref(), Some("F2"));
                    }
                    _ => panic!(),
                }
            }
            _ => panic!(),
        }
    }

    #[test]
    fn lex_hex_and_suffix() {
        let toks = tokenize("0xFFu 1L 1e3 .5 0b101").unwrap();
        assert_eq!(toks[0].tok, Tok::Lit(Lit::UInt(255)));
        assert_eq!(toks[1].tok, Tok::Lit(Lit::Long(1)));
        assert_eq!(toks[2].tok, Tok::Lit(Lit::Double(1000.0)));
        assert_eq!(toks[3].tok, Tok::Lit(Lit::Double(0.5)));
        assert_eq!(toks[4].tok, Tok::Lit(Lit::Int(5)));
    }
}
