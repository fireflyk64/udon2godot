//! Recursive-descent parser for the UdonSharp subset of C#.

use crate::ast::*;
use crate::diag::{ParseError, Span};
use crate::lexer::tokenize;
use crate::token::{InterpPart, Kw, Lit, Tok, Token, P};

pub struct Parser {
    toks: Vec<Token>,
    pos: usize,
    namespace: Vec<String>,
}

type PResult<T> = Result<T, ParseError>;

pub fn parse_source(src: &str, path: &str) -> PResult<CompilationUnit> {
    let toks = tokenize(src)?;
    let mut p = Parser { toks, pos: 0, namespace: Vec::new() };
    let mut cu = p.parse_compilation_unit()?;
    cu.path = path.to_string();
    Ok(cu)
}

/// Parse a standalone expression (used for interpolated string holes).
pub fn parse_expression(src: &str, base: Span) -> PResult<Expr> {
    let mut toks = tokenize(src)?;
    for t in &mut toks {
        t.span = Span::new(base.line, base.col + t.span.col.saturating_sub(1));
    }
    let mut p = Parser { toks, pos: 0, namespace: Vec::new() };
    let e = p.parse_expr()?;
    if !p.at_eof() {
        return Err(p.error("unexpected token after expression"));
    }
    Ok(e)
}

impl Parser {
    // ----- token helpers -----

    fn peek(&self) -> &Token {
        &self.toks[self.pos]
    }

    fn peek_at(&self, n: usize) -> &Token {
        let i = std::cmp::min(self.pos + n, self.toks.len() - 1);
        &self.toks[i]
    }

    fn span(&self) -> Span {
        self.peek().span
    }

    fn at_eof(&self) -> bool {
        self.peek().tok == Tok::Eof
    }

    fn advance(&mut self) -> Token {
        let t = self.toks[self.pos].clone();
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
        t
    }

    fn error(&self, msg: impl Into<String>) -> ParseError {
        ParseError { span: self.span(), message: format!("{} (found {})", msg.into(), self.peek().describe()) }
    }

    fn is_punct(&self, p: P) -> bool {
        self.peek().tok == Tok::Punct(p)
    }

    fn is_punct_at(&self, n: usize, p: P) -> bool {
        self.peek_at(n).tok == Tok::Punct(p)
    }

    fn is_kw(&self, k: Kw) -> bool {
        self.peek().tok == Tok::Keyword(k)
    }

    fn is_ident(&self) -> bool {
        matches!(self.peek().tok, Tok::Ident(_))
    }

    fn is_ident_named(&self, s: &str) -> bool {
        matches!(&self.peek().tok, Tok::Ident(n) if n == s)
    }

    fn eat_punct(&mut self, p: P) -> bool {
        if self.is_punct(p) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn eat_kw(&mut self, k: Kw) -> bool {
        if self.is_kw(k) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn expect_punct(&mut self, p: P) -> PResult<Span> {
        if self.is_punct(p) {
            Ok(self.advance().span)
        } else {
            Err(self.error(format!("expected `{}`", p.as_str())))
        }
    }

    fn expect_kw(&mut self, k: Kw) -> PResult<Span> {
        if self.is_kw(k) {
            Ok(self.advance().span)
        } else {
            Err(self.error(format!("expected `{}`", k.as_str())))
        }
    }

    fn expect_ident(&mut self) -> PResult<String> {
        match &self.peek().tok {
            Tok::Ident(s) => {
                let s = s.clone();
                self.advance();
                Ok(s)
            }
            _ => Err(self.error("expected identifier")),
        }
    }

    /// `>` `>` adjacent tokens form `>>`.
    fn is_shift_right(&self) -> bool {
        self.is_punct(P::Gt) && self.is_punct_at(1, P::Gt) && self.peek_at(1).offset == self.peek().offset + 1
    }

    /// `>` `>=` adjacent tokens form `>>=` (the lexer emits `>` then `>=`).
    fn is_shift_right_assign(&self) -> bool {
        self.is_punct(P::Gt) && self.is_punct_at(1, P::GtEq) && self.peek_at(1).offset == self.peek().offset + 1
    }

    // ----- compilation unit -----

    fn parse_compilation_unit(&mut self) -> PResult<CompilationUnit> {
        let mut cu = CompilationUnit::default();
        while !self.at_eof() {
            if self.is_kw(Kw::Using) {
                self.advance();
                // using static X; using A = B;
                if self.is_ident_named("static") {
                    self.advance();
                }
                let name = self.parse_qualified_name()?;
                if self.eat_punct(P::Eq) {
                    let _ = self.parse_type()?;
                }
                self.expect_punct(P::Semi)?;
                cu.usings.push(name);
            } else if self.is_kw(Kw::Namespace) {
                self.advance();
                let name = self.parse_qualified_name()?;
                if self.eat_punct(P::Semi) {
                    // file-scoped namespace
                    self.namespace.push(name);
                    continue;
                }
                self.expect_punct(P::LBrace)?;
                self.namespace.push(name);
                while !self.is_punct(P::RBrace) && !self.at_eof() {
                    if self.is_kw(Kw::Using) {
                        // using X; using static X; using A = B; (inside a namespace body)
                        self.advance();
                        if self.is_ident_named("static") {
                            self.advance();
                        }
                        let _ = self.parse_qualified_name()?;
                        if self.eat_punct(P::Eq) {
                            let _ = self.parse_type()?;
                        }
                        self.expect_punct(P::Semi)?;
                        continue;
                    }
                    if self.is_kw(Kw::Namespace) {
                        // nested namespace
                        self.advance();
                        let inner = self.parse_qualified_name()?;
                        self.expect_punct(P::LBrace)?;
                        self.namespace.push(inner);
                        while !self.is_punct(P::RBrace) && !self.at_eof() {
                            let t = self.parse_type_decl()?;
                            cu.types.push(t);
                        }
                        self.expect_punct(P::RBrace)?;
                        self.namespace.pop();
                        continue;
                    }
                    let t = self.parse_type_decl()?;
                    cu.types.push(t);
                }
                self.expect_punct(P::RBrace)?;
                self.namespace.pop();
            } else if self.is_punct(P::Semi) {
                self.advance();
            } else if self.is_punct(P::LBracket) && matches!(&self.peek_at(1).tok, Tok::Ident(s) if s == "assembly" || s == "module") && self.is_punct_at(2, P::Colon) {
                // assembly-level attribute: skip
                self.skip_balanced(P::LBracket, P::RBracket)?;
            } else {
                let t = self.parse_type_decl()?;
                cu.types.push(t);
            }
        }
        Ok(cu)
    }

    fn current_namespace(&self) -> String {
        self.namespace.join(".")
    }

    fn parse_qualified_name(&mut self) -> PResult<String> {
        let mut s = self.expect_ident()?;
        while self.is_punct(P::Dot) {
            self.advance();
            s.push('.');
            s.push_str(&self.expect_ident()?);
        }
        Ok(s)
    }

    // ----- attributes & modifiers -----

    fn parse_attributes(&mut self) -> PResult<Vec<Attribute>> {
        let mut attrs = Vec::new();
        while self.is_punct(P::LBracket) {
            // Distinguish from array-typed things: at member position `[` always begins attributes.
            self.advance();
            // optional target: `field:` `return:` etc.
            if self.is_ident() && self.is_punct_at(1, P::Colon) {
                self.advance();
                self.advance();
            } else if (self.is_kw(Kw::Return) || self.is_kw(Kw::Event)) && self.is_punct_at(1, P::Colon) {
                self.advance();
                self.advance();
            }
            loop {
                let span = self.span();
                let name = self.parse_qualified_name()?;
                let short = name.rsplit('.').next().unwrap_or(&name).to_string();
                let mut args = Vec::new();
                if self.eat_punct(P::LParen) {
                    while !self.is_punct(P::RParen) {
                        let mut arg_name = None;
                        if self.is_ident() && (self.is_punct_at(1, P::Eq) || self.is_punct_at(1, P::Colon)) {
                            arg_name = Some(self.expect_ident()?);
                            self.advance();
                        }
                        let start = self.pos;
                        let e = self.parse_expr()?;
                        let text = self.source_text(start, self.pos);
                        let string_value = match e.unparen() {
                            Expr::Lit(Lit::Str(s), _) => Some(s.clone()),
                            Expr::Nameof(inner, _) => inner.as_dotted_name().map(|d| d.rsplit('.').next().unwrap().to_string()),
                            _ => None,
                        };
                        args.push(AttrArg { name: arg_name, text, string_value });
                        if !self.eat_punct(P::Comma) {
                            break;
                        }
                    }
                    self.expect_punct(P::RParen)?;
                }
                attrs.push(Attribute { name: short, args, span });
                if !self.eat_punct(P::Comma) {
                    break;
                }
                if self.is_punct(P::RBracket) {
                    break;
                }
            }
            self.expect_punct(P::RBracket)?;
        }
        Ok(attrs)
    }

    fn source_text(&self, from: usize, to: usize) -> String {
        // Reconstruct approximate source text from tokens.
        let mut s = String::new();
        for t in &self.toks[from..to] {
            let piece = match &t.tok {
                Tok::Ident(i) => i.clone(),
                Tok::Keyword(k) => k.as_str().to_string(),
                Tok::Lit(Lit::Str(v)) => format!("\"{}\"", v),
                Tok::Lit(Lit::Int(v)) => v.to_string(),
                Tok::Lit(Lit::UInt(v)) | Tok::Lit(Lit::ULong(v)) => v.to_string(),
                Tok::Lit(Lit::Long(v)) => v.to_string(),
                Tok::Lit(Lit::Float(v)) | Tok::Lit(Lit::Double(v)) => v.to_string(),
                Tok::Lit(Lit::Char(c)) => format!("'{}'", c),
                Tok::Lit(Lit::Bool(b)) => b.to_string(),
                Tok::Lit(Lit::Null) => "null".into(),
                Tok::InterpStr(_) => "$\"...\"".into(),
                Tok::Punct(p) => p.as_str().to_string(),
                Tok::Eof => String::new(),
            };
            if !s.is_empty() && !matches!(&t.tok, Tok::Punct(P::Dot) | Tok::Punct(P::LParen) | Tok::Punct(P::RParen) | Tok::Punct(P::Comma))
                && !s.ends_with('.') && !s.ends_with('(')
            {
                s.push(' ');
            }
            s.push_str(&piece);
        }
        s
    }

    fn parse_modifiers(&mut self) -> Vec<Modifier> {
        let mut mods = Vec::new();
        loop {
            let m = match &self.peek().tok {
                Tok::Keyword(Kw::Public) => Modifier::Public,
                Tok::Keyword(Kw::Private) => Modifier::Private,
                Tok::Keyword(Kw::Protected) => Modifier::Protected,
                Tok::Keyword(Kw::Internal) => Modifier::Internal,
                Tok::Keyword(Kw::Static) => Modifier::Static,
                Tok::Keyword(Kw::Readonly) => Modifier::Readonly,
                Tok::Keyword(Kw::Const) => Modifier::Const,
                Tok::Keyword(Kw::Override) => Modifier::Override,
                Tok::Keyword(Kw::Virtual) => Modifier::Virtual,
                Tok::Keyword(Kw::Abstract) => Modifier::Abstract,
                Tok::Keyword(Kw::Sealed) => Modifier::Sealed,
                Tok::Keyword(Kw::New) => {
                    // `new` as modifier only if followed by a type-ish token and not `(`
                    if self.is_punct_at(1, P::LParen) {
                        break;
                    }
                    Modifier::New
                }
                Tok::Keyword(Kw::Extern) => Modifier::Extern,
                Tok::Keyword(Kw::Unsafe) => Modifier::Unsafe,
                Tok::Keyword(Kw::Volatile) => Modifier::Volatile,
                Tok::Ident(s) if s == "partial" => {
                    // `partial` is contextual: only a modifier when followed by class/struct/void/type
                    match &self.peek_at(1).tok {
                        Tok::Keyword(Kw::Class) | Tok::Keyword(Kw::Struct) | Tok::Keyword(Kw::Interface) | Tok::Keyword(Kw::Void) => Modifier::Partial,
                        _ => break,
                    }
                }
                Tok::Ident(s) if s == "async" => {
                    // async is not supported but parse it as a no-op modifier
                    match &self.peek_at(1).tok {
                        Tok::Ident(_) | Tok::Keyword(_) => Modifier::Extern,
                        _ => break,
                    }
                }
                _ => break,
            };
            self.advance();
            mods.push(m);
        }
        mods
    }

    // ----- type declarations -----

    fn parse_type_decl(&mut self) -> PResult<TypeDecl> {
        let doc = self.peek().doc.clone();
        let attrs = self.parse_attributes()?;
        let doc = doc.or_else(|| self.peek().doc.clone());
        let modifiers = self.parse_modifiers();
        if self.is_kw(Kw::Class) || self.is_kw(Kw::Struct) || self.is_kw(Kw::Interface) {
            let span = self.advance().span;
            let name = self.expect_ident()?;
            // generic type params (unsupported; parse and ignore)
            if self.is_punct(P::Lt) {
                self.skip_balanced(P::Lt, P::Gt)?;
            }
            let mut bases = Vec::new();
            if self.eat_punct(P::Colon) {
                loop {
                    bases.push(self.parse_type()?);
                    if !self.eat_punct(P::Comma) {
                        break;
                    }
                }
            }
            // where clauses
            while self.is_ident_named("where") {
                while !self.is_punct(P::LBrace) && !self.at_eof() {
                    self.advance();
                }
            }
            self.expect_punct(P::LBrace)?;
            let mut members = Vec::new();
            while !self.is_punct(P::RBrace) && !self.at_eof() {
                if self.eat_punct(P::Semi) {
                    continue;
                }
                let m = self.parse_member(&name)?;
                members.push(m);
            }
            self.expect_punct(P::RBrace)?;
            self.eat_punct(P::Semi);
            Ok(TypeDecl::Class(ClassDecl { name, namespace: self.current_namespace(), attrs, modifiers, bases, members, doc, span }))
        } else if self.is_kw(Kw::Enum) {
            let span = self.advance().span;
            let name = self.expect_ident()?;
            let underlying = if self.eat_punct(P::Colon) { Some(self.parse_type()?) } else { None };
            self.expect_punct(P::LBrace)?;
            let mut members = Vec::new();
            while !self.is_punct(P::RBrace) {
                let _ = self.parse_attributes()?;
                let mspan = self.span();
                let mname = self.expect_ident()?;
                let value = if self.eat_punct(P::Eq) { Some(self.parse_expr()?) } else { None };
                members.push(EnumMember { name: mname, value, span: mspan });
                if !self.eat_punct(P::Comma) {
                    break;
                }
            }
            self.expect_punct(P::RBrace)?;
            self.eat_punct(P::Semi);
            Ok(TypeDecl::Enum(EnumDecl { name, namespace: self.current_namespace(), attrs, underlying, members, span }))
        } else if self.is_kw(Kw::Delegate) {
            Err(self.error("delegates are not supported by Udon"))
        } else {
            Err(self.error("expected type declaration"))
        }
    }

    fn skip_balanced(&mut self, open: P, close: P) -> PResult<()> {
        self.expect_punct(open)?;
        let mut depth = 1;
        while depth > 0 {
            if self.at_eof() {
                return Err(self.error("unbalanced brackets"));
            }
            if self.is_punct(open) {
                depth += 1;
            } else if self.is_punct(close) {
                depth -= 1;
            }
            self.advance();
        }
        Ok(())
    }

    fn parse_member(&mut self, class_name: &str) -> PResult<Member> {
        let doc = self.peek().doc.clone();
        let attrs = self.parse_attributes()?;
        let doc = doc.or_else(|| self.peek().doc.clone());
        let modifiers = self.parse_modifiers();
        let span = self.span();

        // nested type
        if self.is_kw(Kw::Class) || self.is_kw(Kw::Enum) || self.is_kw(Kw::Struct) || self.is_kw(Kw::Interface) {
            // Re-parse with attrs/modifiers already consumed: build manually.
            let td = self.parse_type_decl_after_modifiers(attrs, modifiers, doc)?;
            return Ok(Member::Type(td));
        }

        // constructor: `Name(`
        if self.is_ident_named(class_name) && self.is_punct_at(1, P::LParen) {
            let name = self.expect_ident()?;
            let params = self.parse_params()?;
            // `: base(...)` / `: this(...)`
            if self.eat_punct(P::Colon) {
                self.advance();
                self.skip_balanced(P::LParen, P::RParen)?;
            }
            let body = Some(self.parse_block()?);
            return Ok(Member::Constructor(MethodDecl { attrs, modifiers, ret: TypeRef::Void, name, type_params: vec![], params, body, doc, span }));
        }
        // destructor
        if self.is_punct(P::Tilde) {
            return Err(self.error("destructors are not supported"));
        }

        // `event` declarations unsupported
        if self.is_kw(Kw::Event) {
            return Err(self.error("events are not supported by Udon"));
        }

        let ty = self.parse_type()?;

        // operator overloads unsupported
        if self.is_kw(Kw::Operator) || (self.is_kw(Kw::Implicit) || self.is_kw(Kw::Explicit)) {
            return Err(self.error("operator overloads are not supported by Udon"));
        }

        // explicit interface impl `IFoo.Bar(` — rare; treat generally via qualified name
        let name = self.expect_ident()?;

        // method
        if self.is_punct(P::LParen) || self.is_punct(P::Lt) {
            let mut type_params = Vec::new();
            if self.eat_punct(P::Lt) {
                loop {
                    type_params.push(self.expect_ident()?);
                    if !self.eat_punct(P::Comma) {
                        break;
                    }
                }
                self.expect_punct(P::Gt)?;
            }
            let params = self.parse_params()?;
            while self.is_ident_named("where") {
                while !self.is_punct(P::LBrace) && !self.is_punct(P::Semi) && !self.is_punct(P::Arrow) && !self.at_eof() {
                    self.advance();
                }
            }
            let body = if self.eat_punct(P::Semi) {
                None
            } else if self.is_punct(P::Arrow) {
                let aspan = self.advance().span;
                let e = self.parse_expr()?;
                self.expect_punct(P::Semi)?;
                let stmt = if ty.is_void() { Stmt::Expr(e, aspan) } else { Stmt::Return(Some(e), aspan) };
                Some(Block { stmts: vec![stmt], span: aspan })
            } else {
                Some(self.parse_block()?)
            };
            return Ok(Member::Method(MethodDecl { attrs, modifiers, ret: ty, name, type_params, params, body, doc, span }));
        }

        // property
        if self.is_punct(P::LBrace) || self.is_punct(P::Arrow) {
            if self.is_punct(P::Arrow) {
                self.advance();
                let e = self.parse_expr()?;
                self.expect_punct(P::Semi)?;
                return Ok(Member::Property(PropertyDecl { attrs, modifiers, ty, name, getter: None, setter: None, expr_body: Some(e), init: None, doc, span }));
            }
            self.expect_punct(P::LBrace)?;
            let mut getter = None;
            let mut setter = None;
            while !self.is_punct(P::RBrace) {
                let _ = self.parse_attributes()?;
                let _ = self.parse_modifiers();
                let aspan = self.span();
                let kind = self.expect_ident()?;
                let body = if self.eat_punct(P::Semi) {
                    None
                } else if self.is_punct(P::Arrow) {
                    self.advance();
                    let e = self.parse_expr()?;
                    self.expect_punct(P::Semi)?;
                    let stmt = if kind == "get" { Stmt::Return(Some(e), aspan) } else { Stmt::Expr(e, aspan) };
                    Some(Block { stmts: vec![stmt], span: aspan })
                } else {
                    Some(self.parse_block()?)
                };
                let acc = Accessor { body, span: aspan };
                match kind.as_str() {
                    "get" => getter = Some(acc),
                    "set" | "init" => setter = Some(acc),
                    _ => return Err(self.error("expected `get` or `set`")),
                }
            }
            self.expect_punct(P::RBrace)?;
            let init = if self.eat_punct(P::Eq) {
                let e = self.parse_var_init()?;
                self.expect_punct(P::Semi)?;
                Some(e)
            } else {
                None
            };
            return Ok(Member::Property(PropertyDecl { attrs, modifiers, ty, name, getter, setter, expr_body: None, init, doc, span }));
        }

        // field(s)
        let mut declarators = Vec::new();
        let mut first_name = Some(name);
        loop {
            let dspan = self.span();
            let dname = match first_name.take() {
                Some(n) => n,
                None => self.expect_ident()?,
            };
            let init = if self.eat_punct(P::Eq) { Some(self.parse_var_init()?) } else { None };
            declarators.push(VarDeclarator { name: dname, init, span: dspan });
            if !self.eat_punct(P::Comma) {
                break;
            }
        }
        self.expect_punct(P::Semi)?;
        Ok(Member::Field(FieldDecl { attrs, modifiers, ty, declarators, doc, span }))
    }

    fn parse_type_decl_after_modifiers(&mut self, attrs: Vec<Attribute>, modifiers: Vec<Modifier>, doc: Option<String>) -> PResult<TypeDecl> {
        // Temporarily re-inject by parsing the rest as a type decl and patching attrs/modifiers.
        let mut td = self.parse_type_decl_body()?;
        match &mut td {
            TypeDecl::Class(c) => {
                c.attrs = attrs;
                c.modifiers = modifiers;
                c.doc = doc;
            }
            TypeDecl::Enum(e) => {
                e.attrs = attrs;
            }
        }
        Ok(td)
    }

    fn parse_type_decl_body(&mut self) -> PResult<TypeDecl> {
        // Same as parse_type_decl but without leading attrs/modifiers.
        let save_pos = self.pos;
        let _ = save_pos;
        // Reuse: parse_type_decl handles the absence of attributes/modifiers gracefully.
        self.parse_type_decl()
    }

    fn parse_params(&mut self) -> PResult<Vec<Param>> {
        self.expect_punct(P::LParen)?;
        let mut params = Vec::new();
        while !self.is_punct(P::RParen) {
            let attrs = self.parse_attributes()?;
            let span = self.span();
            let mode = if self.eat_kw(Kw::Ref) {
                ParamMode::Ref
            } else if self.eat_kw(Kw::Out) {
                ParamMode::Out
            } else if self.eat_kw(Kw::Params) {
                ParamMode::Params
            } else {
                if self.eat_kw(Kw::In) {
                    // `in` parameter — treat as value
                }
                ParamMode::Value
            };
            let this = self.is_kw(Kw::This);
            if this {
                self.advance();
            }
            let ty = self.parse_type()?;
            let name = self.expect_ident()?;
            let default = if self.eat_punct(P::Eq) { Some(self.parse_expr()?) } else { None };
            params.push(Param { attrs, this, mode, ty, name, default, span });
            if !self.eat_punct(P::Comma) {
                break;
            }
        }
        self.expect_punct(P::RParen)?;
        Ok(params)
    }

    // ----- types -----

    /// Parse a type. Handles builtin keywords, qualified names, generics, arrays, nullable.
    pub fn parse_type(&mut self) -> PResult<TypeRef> {
        let mut t = match &self.peek().tok {
            Tok::Keyword(Kw::Void) => {
                self.advance();
                TypeRef::Void
            }
            Tok::Keyword(k) if k.is_builtin_type() => {
                let k = *k;
                self.advance();
                TypeRef::named(k.as_str())
            }
            Tok::Ident(s) if s == "var" => {
                self.advance();
                TypeRef::Var
            }
            Tok::Ident(_) => {
                let mut name = self.expect_ident()?;
                let mut args = Vec::new();
                loop {
                    if self.is_punct(P::Lt) {
                        args = self.parse_type_args()?;
                    }
                    if self.is_punct(P::Dot) && matches!(self.peek_at(1).tok, Tok::Ident(_)) {
                        self.advance();
                        name.push('.');
                        name.push_str(&self.expect_ident()?);
                        continue;
                    }
                    if self.is_punct(P::ColonColon) {
                        // global::X
                        self.advance();
                        name = self.expect_ident()?;
                        continue;
                    }
                    break;
                }
                TypeRef::Named { name, args }
            }
            _ => return Err(self.error("expected type")),
        };
        loop {
            if self.is_punct(P::Question) {
                // nullable — but avoid consuming ternary `?` in expression contexts: callers only
                // call parse_type in declaration positions or with speculation.
                self.advance();
                t = TypeRef::Nullable(Box::new(t));
                continue;
            }
            if self.is_punct(P::LBracket) {
                // array rank specifier: `[]`, `[,]` — but not `[expr]`
                let mut n = 1;
                let mut i = 1;
                let mut ok = true;
                loop {
                    match &self.peek_at(i).tok {
                        Tok::Punct(P::Comma) => {
                            n += 1;
                            i += 1;
                        }
                        Tok::Punct(P::RBracket) => break,
                        _ => {
                            ok = false;
                            break;
                        }
                    }
                }
                if !ok {
                    break;
                }
                for _ in 0..=i {
                    self.advance();
                }
                t = TypeRef::Array { elem: Box::new(t), rank: n };
                continue;
            }
            break;
        }
        Ok(t)
    }

    fn parse_type_args(&mut self) -> PResult<Vec<TypeRef>> {
        self.expect_punct(P::Lt)?;
        let mut args = Vec::new();
        loop {
            args.push(self.parse_type()?);
            if !self.eat_punct(P::Comma) {
                break;
            }
        }
        self.expect_punct(P::Gt)?;
        Ok(args)
    }

    /// Speculatively parse a type; restore position on failure.
    fn try_parse_type(&mut self) -> Option<TypeRef> {
        let save = self.pos;
        match self.parse_type() {
            Ok(t) => Some(t),
            Err(_) => {
                self.pos = save;
                None
            }
        }
    }

    // ----- statements -----

    fn parse_block(&mut self) -> PResult<Block> {
        let span = self.expect_punct(P::LBrace)?;
        let mut stmts = Vec::new();
        while !self.is_punct(P::RBrace) {
            if self.at_eof() {
                return Err(self.error("unexpected end of file in block"));
            }
            stmts.push(self.parse_stmt()?);
        }
        self.expect_punct(P::RBrace)?;
        Ok(Block { stmts, span })
    }

    fn parse_embedded(&mut self) -> PResult<Box<Stmt>> {
        Ok(Box::new(self.parse_stmt()?))
    }

    fn parse_stmt(&mut self) -> PResult<Stmt> {
        let span = self.span();
        match &self.peek().tok {
            Tok::Punct(P::LBrace) => Ok(Stmt::Block(self.parse_block()?)),
            Tok::Punct(P::Semi) => {
                self.advance();
                Ok(Stmt::Empty(span))
            }
            Tok::Keyword(Kw::If) => {
                self.advance();
                self.expect_punct(P::LParen)?;
                let cond = self.parse_expr()?;
                self.expect_punct(P::RParen)?;
                let then = self.parse_embedded()?;
                let els = if self.eat_kw(Kw::Else) { Some(self.parse_embedded()?) } else { None };
                Ok(Stmt::If { cond, then, els, span })
            }
            Tok::Keyword(Kw::While) => {
                self.advance();
                self.expect_punct(P::LParen)?;
                let cond = self.parse_expr()?;
                self.expect_punct(P::RParen)?;
                let body = self.parse_embedded()?;
                Ok(Stmt::While { cond, body, span })
            }
            Tok::Keyword(Kw::Do) => {
                self.advance();
                let body = self.parse_embedded()?;
                self.expect_kw(Kw::While)?;
                self.expect_punct(P::LParen)?;
                let cond = self.parse_expr()?;
                self.expect_punct(P::RParen)?;
                self.expect_punct(P::Semi)?;
                Ok(Stmt::DoWhile { body, cond, span })
            }
            Tok::Keyword(Kw::For) => {
                self.advance();
                self.expect_punct(P::LParen)?;
                let mut init = Vec::new();
                if !self.is_punct(P::Semi) {
                    if let Some(decl) = self.try_parse_local_decl(false)? {
                        init.push(decl);
                    } else {
                        loop {
                            let e = self.parse_expr()?;
                            init.push(Stmt::Expr(e, span));
                            if !self.eat_punct(P::Comma) {
                                break;
                            }
                        }
                    }
                }
                self.expect_punct(P::Semi)?;
                let cond = if self.is_punct(P::Semi) { None } else { Some(self.parse_expr()?) };
                self.expect_punct(P::Semi)?;
                let mut update = Vec::new();
                if !self.is_punct(P::RParen) {
                    loop {
                        update.push(self.parse_expr()?);
                        if !self.eat_punct(P::Comma) {
                            break;
                        }
                    }
                }
                self.expect_punct(P::RParen)?;
                let body = self.parse_embedded()?;
                Ok(Stmt::For { init, cond, update, body, span })
            }
            Tok::Keyword(Kw::Foreach) => {
                self.advance();
                self.expect_punct(P::LParen)?;
                let ty = self.parse_type()?;
                let name = self.expect_ident()?;
                self.expect_kw(Kw::In)?;
                let iter = self.parse_expr()?;
                self.expect_punct(P::RParen)?;
                let body = self.parse_embedded()?;
                Ok(Stmt::Foreach { ty, name, iter, body, span })
            }
            Tok::Keyword(Kw::Switch) => {
                self.advance();
                self.expect_punct(P::LParen)?;
                let subject = self.parse_expr()?;
                self.expect_punct(P::RParen)?;
                self.expect_punct(P::LBrace)?;
                let mut sections = Vec::new();
                while !self.is_punct(P::RBrace) {
                    let sspan = self.span();
                    let mut labels = Vec::new();
                    loop {
                        if self.eat_kw(Kw::Case) {
                            let e = self.parse_expr()?;
                            // pattern `case int x:` / `case X when ...` unsupported
                            if self.is_ident_named("when") {
                                return Err(self.error("`case ... when` is not supported"));
                            }
                            self.expect_punct(P::Colon)?;
                            labels.push(SwitchLabel::Case(e));
                        } else if self.eat_kw(Kw::Default) {
                            self.expect_punct(P::Colon)?;
                            labels.push(SwitchLabel::Default);
                        } else {
                            break;
                        }
                    }
                    if labels.is_empty() {
                        return Err(self.error("expected `case` or `default`"));
                    }
                    let mut body = Vec::new();
                    while !self.is_kw(Kw::Case) && !self.is_kw(Kw::Default) && !self.is_punct(P::RBrace) {
                        body.push(self.parse_stmt()?);
                    }
                    sections.push(SwitchSection { labels, body, span: sspan });
                }
                self.expect_punct(P::RBrace)?;
                Ok(Stmt::Switch { subject, sections, span })
            }
            Tok::Keyword(Kw::Break) => {
                self.advance();
                self.expect_punct(P::Semi)?;
                Ok(Stmt::Break(span))
            }
            Tok::Keyword(Kw::Continue) => {
                self.advance();
                self.expect_punct(P::Semi)?;
                Ok(Stmt::Continue(span))
            }
            Tok::Keyword(Kw::Return) => {
                self.advance();
                let e = if self.is_punct(P::Semi) { None } else { Some(self.parse_expr()?) };
                self.expect_punct(P::Semi)?;
                Ok(Stmt::Return(e, span))
            }
            Tok::Keyword(Kw::Throw) => {
                self.advance();
                let e = if self.is_punct(P::Semi) { None } else { Some(self.parse_expr()?) };
                self.expect_punct(P::Semi)?;
                Ok(Stmt::Throw(e, span))
            }
            Tok::Keyword(Kw::Try) => {
                self.advance();
                let body = self.parse_block()?;
                let mut catches = Vec::new();
                while self.eat_kw(Kw::Catch) {
                    if self.eat_punct(P::LParen) {
                        let _ = self.parse_type()?;
                        if self.is_ident() {
                            self.advance();
                        }
                        self.expect_punct(P::RParen)?;
                    }
                    if self.is_ident_named("when") {
                        self.advance();
                        self.skip_balanced(P::LParen, P::RParen)?;
                    }
                    catches.push(self.parse_block()?);
                }
                let finally = if self.eat_kw(Kw::Finally) { Some(self.parse_block()?) } else { None };
                Ok(Stmt::Try { body, catches, finally, span })
            }
            Tok::Keyword(Kw::Lock) => {
                self.advance();
                self.expect_punct(P::LParen)?;
                let _ = self.parse_expr()?;
                self.expect_punct(P::RParen)?;
                let body = self.parse_embedded()?;
                Ok(Stmt::Lock { body, span })
            }
            Tok::Keyword(Kw::Goto) => {
                self.advance();
                if self.eat_kw(Kw::Case) {
                    let e = self.parse_expr()?;
                    self.expect_punct(P::Semi)?;
                    return Ok(Stmt::GotoCase(Some(e), span));
                }
                if self.eat_kw(Kw::Default) {
                    self.expect_punct(P::Semi)?;
                    return Ok(Stmt::GotoCase(None, span));
                }
                let l = self.expect_ident()?;
                self.expect_punct(P::Semi)?;
                Ok(Stmt::Goto(l, span))
            }
            Tok::Keyword(Kw::Const) => {
                self.advance();
                let d = self.try_parse_local_decl(true)?.ok_or_else(|| self.error("expected constant declaration"))?;
                self.expect_punct(P::Semi)?;
                Ok(d)
            }
            Tok::Keyword(Kw::Using) => Err(self.error("`using` statements are not supported")),
            Tok::Keyword(Kw::Unsafe) | Tok::Keyword(Kw::Fixed) => Err(self.error("unsafe code is not supported")),
            Tok::Keyword(Kw::Checked) | Tok::Keyword(Kw::Unchecked) if self.is_punct_at(1, P::LBrace) => {
                self.advance();
                Ok(Stmt::Block(self.parse_block()?))
            }
            Tok::Ident(_) if self.is_punct_at(1, P::Colon) && !self.is_punct_at(2, P::Colon) => {
                // label
                let l = self.expect_ident()?;
                self.advance();
                Ok(Stmt::Label(l, span))
            }
            _ => {
                if let Some(decl) = self.try_parse_local_decl(false)? {
                    self.expect_punct(P::Semi)?;
                    return Ok(decl);
                }
                let e = self.parse_expr()?;
                self.expect_punct(P::Semi)?;
                Ok(Stmt::Expr(e, span))
            }
        }
    }

    /// Try to parse `Type name [= init] [, name [= init]]*` (without the trailing `;`).
    fn try_parse_local_decl(&mut self, is_const: bool) -> PResult<Option<Stmt>> {
        let span = self.span();
        let save = self.pos;
        // Quick reject: must start with ident or builtin type keyword
        let starts_ok = match &self.peek().tok {
            Tok::Ident(_) => true,
            Tok::Keyword(k) => k.is_builtin_type(),
            _ => false,
        };
        if !starts_ok {
            return Ok(None);
        }
        let ty = match self.try_parse_type() {
            Some(t) => t,
            None => {
                self.pos = save;
                return Ok(None);
            }
        };
        // Must be followed by identifier then one of `=`, `;`, `,`, `)` (for-init), `in` (foreach handled elsewhere)
        let is_decl = self.is_ident()
            && matches!(self.peek_at(1).tok, Tok::Punct(P::Eq) | Tok::Punct(P::Semi) | Tok::Punct(P::Comma) | Tok::Punct(P::RParen));
        if !is_decl {
            self.pos = save;
            return Ok(None);
        }
        let mut declarators = Vec::new();
        loop {
            let dspan = self.span();
            let name = self.expect_ident()?;
            let init = if self.eat_punct(P::Eq) { Some(self.parse_var_init()?) } else { None };
            declarators.push(VarDeclarator { name, init, span: dspan });
            if !self.eat_punct(P::Comma) {
                break;
            }
        }
        Ok(Some(Stmt::LocalDecl { ty, declarators, is_const, span }))
    }

    /// Variable initializer: expression or `{ a, b, c }` array initializer.
    fn parse_var_init(&mut self) -> PResult<Expr> {
        if self.is_punct(P::LBrace) {
            let span = self.span();
            let items = self.parse_array_init_body()?;
            return Ok(Expr::ArrayInit(items, span));
        }
        self.parse_expr()
    }

    fn parse_array_init_body(&mut self) -> PResult<Vec<Expr>> {
        self.expect_punct(P::LBrace)?;
        let mut items = Vec::new();
        while !self.is_punct(P::RBrace) {
            if self.is_punct(P::LBrace) {
                let span = self.span();
                let inner = self.parse_array_init_body()?;
                items.push(Expr::ArrayInit(inner, span));
            } else if self.is_punct(P::LBracket) {
                // index initializer `[key] = value` of an object initializer: the target is the
                // object under construction, named `$init` until the initializer is lowered
                let span = self.span();
                self.advance();
                let mut indices = vec![self.parse_expr()?];
                while self.eat_punct(P::Comma) {
                    indices.push(self.parse_expr()?);
                }
                self.expect_punct(P::RBracket)?;
                self.expect_punct(P::Eq)?;
                let rhs = if self.is_punct(P::LBrace) {
                    let s2 = self.span();
                    Expr::ArrayInit(self.parse_array_init_body()?, s2)
                } else {
                    self.parse_expr()?
                };
                let lhs = Expr::Index { target: Box::new(Expr::Ident("$init".into(), span)), indices, null_cond: false, span };
                items.push(Expr::Assign { op: None, lhs: Box::new(lhs), rhs: Box::new(rhs), span });
            } else {
                items.push(self.parse_expr()?);
            }
            if !self.eat_punct(P::Comma) {
                break;
            }
        }
        self.expect_punct(P::RBrace)?;
        Ok(items)
    }

    // ----- expressions -----

    pub fn parse_expr(&mut self) -> PResult<Expr> {
        self.parse_assignment()
    }

    fn parse_assignment(&mut self) -> PResult<Expr> {
        // lambda: `x => ...` or `(a, b) => ...` or `() => ...`
        if self.is_ident() && self.is_punct_at(1, P::Arrow) {
            let span = self.span();
            let p = self.expect_ident()?;
            self.advance();
            let body = self.parse_lambda_body()?;
            return Ok(Expr::Lambda { params: vec![p], body: Box::new(body), span });
        }
        if self.is_punct(P::LParen) && self.looks_like_lambda_params() {
            let span = self.span();
            self.advance();
            let mut params = Vec::new();
            while !self.is_punct(P::RParen) {
                // optional type
                if !(self.is_ident() && (self.is_punct_at(1, P::Comma) || self.is_punct_at(1, P::RParen))) {
                    let _ = self.parse_type()?;
                }
                params.push(self.expect_ident()?);
                if !self.eat_punct(P::Comma) {
                    break;
                }
            }
            self.expect_punct(P::RParen)?;
            self.expect_punct(P::Arrow)?;
            let body = self.parse_lambda_body()?;
            return Ok(Expr::Lambda { params, body: Box::new(body), span });
        }

        let lhs = self.parse_conditional()?;
        let span = lhs.span();
        let op = match &self.peek().tok {
            Tok::Punct(P::Eq) => Some(None),
            Tok::Punct(P::PlusEq) => Some(Some(BinOp::Add)),
            Tok::Punct(P::MinusEq) => Some(Some(BinOp::Sub)),
            Tok::Punct(P::StarEq) => Some(Some(BinOp::Mul)),
            Tok::Punct(P::SlashEq) => Some(Some(BinOp::Div)),
            Tok::Punct(P::PercentEq) => Some(Some(BinOp::Rem)),
            Tok::Punct(P::AmpEq) => Some(Some(BinOp::BitAnd)),
            Tok::Punct(P::PipeEq) => Some(Some(BinOp::BitOr)),
            Tok::Punct(P::CaretEq) => Some(Some(BinOp::BitXor)),
            Tok::Punct(P::LtLtEq) => Some(Some(BinOp::Shl)),
            Tok::Punct(P::QuestionQuestionEq) => Some(Some(BinOp::Coalesce)),
            Tok::Punct(P::Gt) if self.is_shift_right_assign() => {
                self.advance();
                Some(Some(BinOp::Shr))
            }
            _ => None,
        };
        if let Some(op) = op {
            self.advance();
            let rhs = self.parse_assignment()?;
            return Ok(Expr::Assign { op, lhs: Box::new(lhs), rhs: Box::new(rhs), span });
        }
        Ok(lhs)
    }

    fn looks_like_lambda_params(&self) -> bool {
        // scan to matching ')' then check for '=>'
        let mut depth = 0;
        let mut i = 0;
        loop {
            match &self.peek_at(i).tok {
                Tok::Punct(P::LParen) => depth += 1,
                Tok::Punct(P::RParen) => {
                    depth -= 1;
                    if depth == 0 {
                        return self.is_punct_at(i + 1, P::Arrow);
                    }
                }
                Tok::Eof => return false,
                Tok::Punct(P::Semi) | Tok::Punct(P::LBrace) | Tok::Punct(P::RBrace) => return false,
                _ => {}
            }
            i += 1;
            if i > 64 {
                return false;
            }
        }
    }

    fn parse_lambda_body(&mut self) -> PResult<LambdaBody> {
        if self.is_punct(P::LBrace) {
            Ok(LambdaBody::Block(self.parse_block()?))
        } else {
            Ok(LambdaBody::Expr(self.parse_expr()?))
        }
    }

    fn parse_conditional(&mut self) -> PResult<Expr> {
        let cond = self.parse_coalesce()?;
        if self.is_punct(P::Question) {
            let span = cond.span();
            self.advance();
            let then = self.parse_assignment()?;
            self.expect_punct(P::Colon)?;
            let els = self.parse_assignment()?;
            return Ok(Expr::Cond { cond: Box::new(cond), then: Box::new(then), els: Box::new(els), span });
        }
        Ok(cond)
    }

    fn parse_coalesce(&mut self) -> PResult<Expr> {
        let lhs = self.parse_or()?;
        if self.is_punct(P::QuestionQuestion) {
            let span = lhs.span();
            self.advance();
            let rhs = self.parse_coalesce()?; // right assoc
            return Ok(Expr::Binary { op: BinOp::Coalesce, lhs: Box::new(lhs), rhs: Box::new(rhs), span });
        }
        Ok(lhs)
    }

    fn parse_binary_level(&mut self, level: u8) -> PResult<Expr> {
        // levels: 0 ||, 1 &&, 2 |, 3 ^, 4 &, 5 equality, 6 relational, 7 shift, 8 additive, 9 multiplicative
        if level > 9 {
            return self.parse_unary();
        }
        let mut lhs = self.parse_binary_level(level + 1)?;
        loop {
            let op = match (level, &self.peek().tok) {
                (0, Tok::Punct(P::PipePipe)) => BinOp::Or,
                (1, Tok::Punct(P::AmpAmp)) => BinOp::And,
                (2, Tok::Punct(P::Pipe)) => BinOp::BitOr,
                (3, Tok::Punct(P::Caret)) => BinOp::BitXor,
                (4, Tok::Punct(P::Amp)) => BinOp::BitAnd,
                (5, Tok::Punct(P::EqEq)) => BinOp::Eq,
                (5, Tok::Punct(P::BangEq)) => BinOp::Ne,
                (6, Tok::Punct(P::Lt)) => BinOp::Lt,
                (6, Tok::Punct(P::LtEq)) => BinOp::Le,
                (6, Tok::Punct(P::Gt)) if !self.is_shift_right() && !self.is_shift_right_assign() => BinOp::Gt,
                (6, Tok::Punct(P::GtEq)) => BinOp::Ge,
                (6, Tok::Keyword(Kw::Is)) => {
                    let span = lhs.span();
                    self.advance();
                    let ty = self.parse_type()?;
                    // pattern `is T name` / `is null` / `is not`
                    if self.is_ident() && !self.is_punct_at(1, P::Dot) {
                        return Err(self.error("pattern matching `is T x` is not supported"));
                    }
                    lhs = Expr::Is { expr: Box::new(lhs), ty, span };
                    continue;
                }
                (6, Tok::Keyword(Kw::As)) => {
                    let span = lhs.span();
                    self.advance();
                    let ty = self.parse_type()?;
                    lhs = Expr::As { expr: Box::new(lhs), ty, span };
                    continue;
                }
                (7, Tok::Punct(P::LtLt)) => BinOp::Shl,
                (7, Tok::Punct(P::Gt)) if self.is_shift_right() => {
                    self.advance();
                    BinOp::Shr
                }
                (8, Tok::Punct(P::Plus)) => BinOp::Add,
                (8, Tok::Punct(P::Minus)) => BinOp::Sub,
                (9, Tok::Punct(P::Star)) => BinOp::Mul,
                (9, Tok::Punct(P::Slash)) => BinOp::Div,
                (9, Tok::Punct(P::Percent)) => BinOp::Rem,
                _ => break,
            };
            let span = lhs.span();
            self.advance();
            let rhs = self.parse_binary_level(level + 1)?;
            lhs = Expr::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Ok(lhs)
    }

    fn parse_or(&mut self) -> PResult<Expr> {
        self.parse_binary_level(0)
    }

    fn parse_unary(&mut self) -> PResult<Expr> {
        let span = self.span();
        match &self.peek().tok {
            Tok::Punct(P::Minus) => {
                self.advance();
                let e = self.parse_unary()?;
                // fold negative literals
                if let Expr::Lit(l, s) = &e {
                    let folded = match l {
                        Lit::Int(v) => Some(Lit::Int(-v)),
                        Lit::Long(v) => Some(Lit::Long(-v)),
                        Lit::Float(v) => Some(Lit::Float(-v)),
                        Lit::Double(v) => Some(Lit::Double(-v)),
                        _ => None,
                    };
                    if let Some(f) = folded {
                        return Ok(Expr::Lit(f, *s));
                    }
                }
                Ok(Expr::Unary { op: UnOp::Neg, expr: Box::new(e), span })
            }
            Tok::Punct(P::Plus) => {
                self.advance();
                let e = self.parse_unary()?;
                Ok(Expr::Unary { op: UnOp::Plus, expr: Box::new(e), span })
            }
            Tok::Punct(P::Bang) => {
                self.advance();
                let e = self.parse_unary()?;
                Ok(Expr::Unary { op: UnOp::Not, expr: Box::new(e), span })
            }
            Tok::Punct(P::Tilde) => {
                self.advance();
                let e = self.parse_unary()?;
                Ok(Expr::Unary { op: UnOp::BitNot, expr: Box::new(e), span })
            }
            Tok::Punct(P::PlusPlus) => {
                self.advance();
                let e = self.parse_unary()?;
                Ok(Expr::Unary { op: UnOp::PreInc, expr: Box::new(e), span })
            }
            Tok::Punct(P::MinusMinus) => {
                self.advance();
                let e = self.parse_unary()?;
                Ok(Expr::Unary { op: UnOp::PreDec, expr: Box::new(e), span })
            }
            Tok::Punct(P::LParen) => {
                if let Some(cast) = self.try_parse_cast()? {
                    return Ok(cast);
                }
                self.parse_postfix()
            }
            Tok::Punct(P::Amp) | Tok::Punct(P::Star) => Err(self.error("pointer operations are not supported")),
            _ => self.parse_postfix(),
        }
    }

    /// Try `(Type) unary-expr`.
    fn try_parse_cast(&mut self) -> PResult<Option<Expr>> {
        let save = self.pos;
        let span = self.span();
        self.advance(); // (
        let is_keyword_type = matches!(&self.peek().tok, Tok::Keyword(k) if k.is_builtin_type());
        let ty = match self.try_parse_type() {
            Some(t) => t,
            None => {
                self.pos = save;
                return Ok(None);
            }
        };
        if !self.is_punct(P::RParen) {
            self.pos = save;
            return Ok(None);
        }
        self.advance(); // )
        // Decide if this is a cast based on the following token.
        let next_is_cast_operand = match &self.peek().tok {
            Tok::Ident(_) => true,
            Tok::Lit(_) => true,
            Tok::InterpStr(_) => true,
            Tok::Keyword(k) => match k {
                Kw::As | Kw::Is => false,
                _ => true, // this, base, new, typeof, default, builtin types, etc.
            },
            Tok::Punct(P::LParen) => true,
            Tok::Punct(P::Bang) | Tok::Punct(P::Tilde) => true,
            Tok::Punct(P::Minus) | Tok::Punct(P::Plus) | Tok::Punct(P::PlusPlus) | Tok::Punct(P::MinusMinus) => is_keyword_type,
            _ => false,
        };
        if !next_is_cast_operand {
            self.pos = save;
            return Ok(None);
        }
        // Heuristic: `(a) (b)` with a non-keyword single identifier type and next `(` — treat as cast
        // (C# does too). `(x) + 1` is handled above (not a cast for non-keyword types).
        let expr = self.parse_unary()?;
        Ok(Some(Expr::Cast { ty, expr: Box::new(expr), span }))
    }

    fn parse_postfix(&mut self) -> PResult<Expr> {
        let mut e = self.parse_primary()?;
        loop {
            let span = e.span();
            match &self.peek().tok {
                Tok::Punct(P::Dot) => {
                    self.advance();
                    let name = self.expect_ident_or_keyword_name()?;
                    e = Expr::Member { target: Box::new(e), name, null_cond: false, span };
                    // generic method call: `.GetComponent<T>(`
                    if self.is_punct(P::Lt) {
                        if let Some(args) = self.try_parse_type_args_before_paren() {
                            e = Expr::GenericName { name: Box::new(e), args, span };
                        }
                    }
                }
                Tok::Punct(P::QuestionDot) => {
                    self.advance();
                    let name = self.expect_ident()?;
                    e = Expr::Member { target: Box::new(e), name, null_cond: true, span };
                }
                Tok::Punct(P::LParen) => {
                    let args = self.parse_args()?;
                    e = Expr::Call { callee: Box::new(e), args, span };
                }
                Tok::Punct(P::LBracket) => {
                    self.advance();
                    let mut indices = Vec::new();
                    loop {
                        indices.push(self.parse_expr()?);
                        if !self.eat_punct(P::Comma) {
                            break;
                        }
                    }
                    self.expect_punct(P::RBracket)?;
                    e = Expr::Index { target: Box::new(e), indices, null_cond: false, span };
                }
                Tok::Punct(P::Question) if self.is_punct_at(1, P::LBracket) => {
                    self.advance();
                    self.advance();
                    let mut indices = Vec::new();
                    loop {
                        indices.push(self.parse_expr()?);
                        if !self.eat_punct(P::Comma) {
                            break;
                        }
                    }
                    self.expect_punct(P::RBracket)?;
                    e = Expr::Index { target: Box::new(e), indices, null_cond: true, span };
                }
                Tok::Punct(P::PlusPlus) => {
                    self.advance();
                    e = Expr::Unary { op: UnOp::PostInc, expr: Box::new(e), span };
                }
                Tok::Punct(P::MinusMinus) => {
                    self.advance();
                    e = Expr::Unary { op: UnOp::PostDec, expr: Box::new(e), span };
                }
                Tok::Punct(P::Bang) if self.is_null_forgiving_context() => {
                    // `x!` null-forgiving — ignore
                    self.advance();
                }
                _ => break,
            }
        }
        Ok(e)
    }

    fn is_null_forgiving_context(&self) -> bool {
        // `!` followed by `.`, `)`, `;`, `,`, `[` → null-forgiving postfix
        matches!(
            self.peek_at(1).tok,
            Tok::Punct(P::Dot) | Tok::Punct(P::RParen) | Tok::Punct(P::Semi) | Tok::Punct(P::Comma) | Tok::Punct(P::LBracket)
        )
    }

    fn expect_ident_or_keyword_name(&mut self) -> PResult<String> {
        match &self.peek().tok {
            Tok::Ident(s) => {
                let s = s.clone();
                self.advance();
                Ok(s)
            }
            Tok::Keyword(k) => {
                // e.g. `.Equals`, `.ToString` are idents; but allow `.@default` etc.
                let s = k.as_str().to_string();
                self.advance();
                Ok(s)
            }
            _ => Err(self.error("expected member name")),
        }
    }

    /// Speculatively parse `<T, U>` only when followed by `(`.
    fn try_parse_type_args_before_paren(&mut self) -> Option<Vec<TypeRef>> {
        let save = self.pos;
        match self.parse_type_args() {
            Ok(args) if self.is_punct(P::LParen) => Some(args),
            _ => {
                self.pos = save;
                None
            }
        }
    }

    fn parse_args(&mut self) -> PResult<Vec<Arg>> {
        self.expect_punct(P::LParen)?;
        let mut args = Vec::new();
        while !self.is_punct(P::RParen) {
            let mut name = None;
            if self.is_ident() && self.is_punct_at(1, P::Colon) && !self.is_punct_at(2, P::Colon) {
                name = Some(self.expect_ident()?);
                self.advance();
            }
            let mode = if self.eat_kw(Kw::Ref) {
                ParamMode::Ref
            } else if self.eat_kw(Kw::Out) {
                ParamMode::Out
            } else {
                if self.is_kw(Kw::In) && !self.is_punct_at(1, P::LParen) {
                    self.advance();
                }
                ParamMode::Value
            };
            let mut out_decl = None;
            let expr = if mode == ParamMode::Out {
                // `out var x` / `out T x` / `out x`
                let save = self.pos;
                if let Some(t) = self.try_parse_type() {
                    if self.is_ident() && (self.is_punct_at(1, P::Comma) || self.is_punct_at(1, P::RParen)) {
                        let span = self.span();
                        let n = self.expect_ident()?;
                        out_decl = Some((t, n.clone()));
                        Expr::Ident(n, span)
                    } else {
                        self.pos = save;
                        self.parse_expr()?
                    }
                } else {
                    self.pos = save;
                    self.parse_expr()?
                }
            } else {
                self.parse_expr()?
            };
            args.push(Arg { name, mode, out_decl, expr });
            if !self.eat_punct(P::Comma) {
                break;
            }
        }
        self.expect_punct(P::RParen)?;
        Ok(args)
    }

    fn parse_primary(&mut self) -> PResult<Expr> {
        let span = self.span();
        let t = self.peek().tok.clone();
        match t {
            Tok::Lit(l) => {
                self.advance();
                Ok(Expr::Lit(l, span))
            }
            Tok::InterpStr(parts) => {
                self.advance();
                let mut pieces = Vec::new();
                for p in parts {
                    match p {
                        InterpPart::Text(s) => pieces.push(InterpPiece::Text(s)),
                        InterpPart::Expr { source, format, span: espan } => {
                            let e = parse_expression(&source, espan)?;
                            pieces.push(InterpPiece::Expr { expr: e, format });
                        }
                    }
                }
                Ok(Expr::Interp(pieces, span))
            }
            Tok::Ident(name) => {
                self.advance();
                // generic name in expression position: `Foo<T>(`
                if self.is_punct(P::Lt) {
                    if let Some(args) = self.try_parse_type_args_before_paren() {
                        return Ok(Expr::GenericName { name: Box::new(Expr::Ident(name, span)), args, span });
                    }
                }
                if name == "nameof" && self.is_punct(P::LParen) {
                    self.advance();
                    let e = self.parse_expr()?;
                    self.expect_punct(P::RParen)?;
                    return Ok(Expr::Nameof(Box::new(e), span));
                }
                Ok(Expr::Ident(name, span))
            }
            Tok::Keyword(Kw::This) => {
                self.advance();
                Ok(Expr::This(span))
            }
            Tok::Keyword(Kw::Base) => {
                self.advance();
                Ok(Expr::Base(span))
            }
            Tok::Keyword(Kw::New) => {
                self.advance();
                // implicitly typed array `new[] { ... }`
                if self.is_punct(P::LBracket) && self.is_punct_at(1, P::RBracket) {
                    self.advance();
                    self.advance();
                    let init = self.parse_array_init_body()?;
                    return Ok(Expr::NewArray { elem: TypeRef::Var, sizes: vec![None], rank: 1, init: Some(init), span });
                }
                // Parse element type without array suffix so we can capture sizes.
                let base_ty = self.parse_type_no_array()?;
                if self.is_punct(P::LBracket) {
                    // array creation: `new T[n]`, `new T[n, m]`, `new T[]{...}`, `new T[n][]` (jagged)
                    self.advance();
                    let mut sizes = Vec::new();
                    let mut rank = 1u32;
                    if self.is_punct(P::RBracket) {
                        sizes.push(None);
                    } else {
                        loop {
                            if self.is_punct(P::Comma) {
                                sizes.push(None);
                            } else if self.is_punct(P::RBracket) {
                                sizes.push(None);
                                break;
                            } else {
                                sizes.push(Some(self.parse_expr()?));
                            }
                            if self.eat_punct(P::Comma) {
                                rank += 1;
                            } else {
                                break;
                            }
                        }
                    }
                    self.expect_punct(P::RBracket)?;
                    let mut elem = base_ty;
                    // jagged suffixes: `new int[3][]`
                    while self.is_punct(P::LBracket) && self.is_punct_at(1, P::RBracket) {
                        self.advance();
                        self.advance();
                        elem = TypeRef::Array { elem: Box::new(elem), rank: 1 };
                    }
                    let init = if self.is_punct(P::LBrace) { Some(self.parse_array_init_body()?) } else { None };
                    return Ok(Expr::NewArray { elem, sizes, rank, init, span });
                }
                let args = if self.is_punct(P::LParen) { self.parse_args()? } else { Vec::new() };
                let init = if self.is_punct(P::LBrace) {
                    // object/collection initializer
                    Some(self.parse_array_init_body()?)
                } else {
                    None
                };
                Ok(Expr::New { ty: base_ty, args, init, span })
            }
            Tok::Keyword(Kw::Typeof) => {
                self.advance();
                self.expect_punct(P::LParen)?;
                let ty = self.parse_type()?;
                self.expect_punct(P::RParen)?;
                Ok(Expr::Typeof(ty, span))
            }
            Tok::Keyword(Kw::Default) => {
                self.advance();
                if self.eat_punct(P::LParen) {
                    let ty = self.parse_type()?;
                    self.expect_punct(P::RParen)?;
                    Ok(Expr::Default(Some(ty), span))
                } else {
                    Ok(Expr::Default(None, span))
                }
            }
            Tok::Keyword(Kw::Sizeof) => Err(self.error("sizeof is not supported")),
            Tok::Keyword(Kw::Checked) | Tok::Keyword(Kw::Unchecked) => {
                let checked = t == Tok::Keyword(Kw::Checked);
                self.advance();
                self.expect_punct(P::LParen)?;
                let e = self.parse_expr()?;
                self.expect_punct(P::RParen)?;
                Ok(Expr::Checked(Box::new(e), checked, span))
            }
            Tok::Keyword(k) if k.is_builtin_type() => {
                // `int.MaxValue`, `string.Empty`, `float.PositiveInfinity`, `(int)` handled elsewhere
                self.advance();
                let ty = TypeRef::named(k.as_str());
                Ok(Expr::TypeExpr(ty, span))
            }
            Tok::Punct(P::LParen) => {
                self.advance();
                // tuple literal unsupported
                let e = self.parse_expr()?;
                if self.is_punct(P::Comma) {
                    return Err(self.error("tuples are not supported"));
                }
                self.expect_punct(P::RParen)?;
                Ok(Expr::Paren(Box::new(e), span))
            }
            Tok::Punct(P::LBrace) => {
                let items = self.parse_array_init_body()?;
                Ok(Expr::ArrayInit(items, span))
            }
            _ => Err(self.error("expected expression")),
        }
    }

    /// Parse a type without consuming trailing `[...]` (used by `new`).
    fn parse_type_no_array(&mut self) -> PResult<TypeRef> {
        let t = match &self.peek().tok {
            Tok::Keyword(k) if k.is_builtin_type() => {
                let k = *k;
                self.advance();
                TypeRef::named(k.as_str())
            }
            Tok::Ident(_) => {
                let mut name = self.expect_ident()?;
                let mut args = Vec::new();
                loop {
                    if self.is_punct(P::Lt) {
                        args = self.parse_type_args()?;
                    }
                    if self.is_punct(P::Dot) && matches!(self.peek_at(1).tok, Tok::Ident(_)) {
                        self.advance();
                        name.push('.');
                        name.push_str(&self.expect_ident()?);
                        continue;
                    }
                    break;
                }
                TypeRef::Named { name, args }
            }
            _ => return Err(self.error("expected type after `new`")),
        };
        if self.is_punct(P::Question) && !self.is_punct_at(1, P::LParen) {
            self.advance();
            return Ok(TypeRef::Nullable(Box::new(t)));
        }
        Ok(t)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(src: &str) -> CompilationUnit {
        parse_source(src, "test.cs").unwrap_or_else(|e| panic!("{}", e))
    }

    #[test]
    fn parse_class_with_members() {
        let cu = parse(
            r#"
            using UdonSharp;
            namespace Foo.Bar {
                [UdonBehaviourSyncMode(BehaviourSyncMode.Manual)]
                public class Thing : UdonSharpBehaviour {
                    [UdonSynced] public int count = 3, other;
                    [SerializeField] private Vector3[] pts = new Vector3[16];
                    public float Speed { get => speed; set { speed = value; } }
                    private float speed = 1.5f;
                    public override void Start() { count++; int x = (int)speed; float y = (float)count / 2f; }
                    public void Go(out float a, ref int b, GameObject[] objs) { a = 1; foreach (var o in objs) { if (o) o.SetActive(!o.activeSelf); } }
                    void Lambda() { var t = transform.GetComponent<Transform>(); int s = count >> 2; bool c = count > 2 && other < 3; }
                }
                public enum Mode { A, B = 5 }
            }
            "#,
        );
        assert_eq!(cu.usings, vec!["UdonSharp"]);
        assert_eq!(cu.types.len(), 2);
        match &cu.types[0] {
            TypeDecl::Class(c) => {
                assert_eq!(c.name, "Thing");
                assert_eq!(c.namespace, "Foo.Bar");
                assert!(c.has_attr("UdonBehaviourSyncMode"));
                assert_eq!(c.members.len(), 7);
            }
            _ => panic!(),
        }
    }

    #[test]
    fn parse_expressions() {
        let cu = parse(
            r#"
            class T {
                void F() {
                    a = b ? c : d;
                    x = (Vector3)(y * 2);
                    z = -1f;
                    w = a.b.c(1, 2)[3].d;
                    s = $"hi {name} {v:F2}";
                    q = new Vector3(1, 2, 3);
                    arr = new int[] { 1, 2, 3 };
                    n = nameof(F);
                    m = x is Foo;
                    k = x as Foo;
                    p = a ?? b;
                    sh = 1 << 3;
                    sr = v >> 2;
                    ge = v >= 2;
                    x += 1; x -= 2; x *= 3; x /= 4; x %= 5; x >>= 1; x <<= 1;
                    switch (m) { case 1: case 2: break; default: return; }
                    for (int i = 0, j = 2; i < 3; i++, j--) { }
                    do { } while (false);
                    t = (T)obj;
                    u = (float)x / 2;
                    neg = (x) - 1;
                    fl = 1e-5f;
                    Physics.Raycast(a, b, out RaycastHit hit, 10f);
                    var arr2 = new float[3, 4];
                    obj?.Method();
                }
            }
            "#,
        );
        assert_eq!(cu.types.len(), 1);
    }
}
