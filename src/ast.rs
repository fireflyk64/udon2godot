//! C# abstract syntax tree for the UdonSharp subset.

use crate::diag::Span;
use crate::token::Lit;

#[derive(Debug, Clone, Default)]
pub struct CompilationUnit {
    pub usings: Vec<String>,
    pub types: Vec<TypeDecl>,
    /// Source file path (for diagnostics/report).
    pub path: String,
}

#[derive(Debug, Clone)]
pub enum TypeDecl {
    Class(ClassDecl),
    Enum(EnumDecl),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Attribute {
    pub name: String,
    pub args: Vec<AttrArg>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AttrArg {
    pub name: Option<String>,
    /// Raw source text of the argument (attributes are only inspected shallowly).
    pub text: String,
    /// If the argument is `nameof(X)` or a string literal, the resolved string.
    pub string_value: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Modifier {
    Public,
    Private,
    Protected,
    Internal,
    Static,
    Readonly,
    Const,
    Override,
    Virtual,
    Abstract,
    Sealed,
    Partial,
    New,
    Extern,
    Unsafe,
    Volatile,
}

#[derive(Debug, Clone)]
pub struct ClassDecl {
    pub name: String,
    pub namespace: String,
    pub attrs: Vec<Attribute>,
    pub modifiers: Vec<Modifier>,
    pub bases: Vec<TypeRef>,
    pub members: Vec<Member>,
    pub doc: Option<String>,
    pub span: Span,
}

impl ClassDecl {
    pub fn is_partial(&self) -> bool {
        self.modifiers.contains(&Modifier::Partial)
    }
    pub fn has_attr(&self, name: &str) -> bool {
        self.attrs.iter().any(|a| a.name == name || a.name == format!("{}Attribute", name))
    }
    pub fn attr(&self, name: &str) -> Option<&Attribute> {
        self.attrs.iter().find(|a| a.name == name || a.name == format!("{}Attribute", name))
    }
}

#[derive(Debug, Clone)]
pub struct EnumDecl {
    pub name: String,
    pub namespace: String,
    pub attrs: Vec<Attribute>,
    pub underlying: Option<TypeRef>,
    pub members: Vec<EnumMember>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct EnumMember {
    pub name: String,
    pub value: Option<Expr>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum Member {
    Field(FieldDecl),
    Property(PropertyDecl),
    Method(MethodDecl),
    /// Nested type declarations (enums are common; nested classes are rare).
    Type(TypeDecl),
    Constructor(MethodDecl),
}

#[derive(Debug, Clone)]
pub struct FieldDecl {
    pub attrs: Vec<Attribute>,
    pub modifiers: Vec<Modifier>,
    pub ty: TypeRef,
    /// One declaration may declare several fields: `int a, b = 2;`
    pub declarators: Vec<VarDeclarator>,
    pub doc: Option<String>,
    pub span: Span,
}

impl FieldDecl {
    pub fn has_attr(&self, name: &str) -> bool {
        self.attrs.iter().any(|a| a.name == name || a.name == format!("{}Attribute", name))
    }
    pub fn attr(&self, name: &str) -> Option<&Attribute> {
        self.attrs.iter().find(|a| a.name == name || a.name == format!("{}Attribute", name))
    }
    pub fn is_static(&self) -> bool {
        self.modifiers.contains(&Modifier::Static)
    }
    pub fn is_const(&self) -> bool {
        self.modifiers.contains(&Modifier::Const)
    }
    pub fn is_public(&self) -> bool {
        self.modifiers.contains(&Modifier::Public)
    }
}

#[derive(Debug, Clone)]
pub struct VarDeclarator {
    pub name: String,
    pub init: Option<Expr>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct PropertyDecl {
    pub attrs: Vec<Attribute>,
    pub modifiers: Vec<Modifier>,
    pub ty: TypeRef,
    pub name: String,
    pub getter: Option<Accessor>,
    pub setter: Option<Accessor>,
    /// `=> expr` expression-bodied property (getter only)
    pub expr_body: Option<Expr>,
    /// Auto-property initializer `{ get; set; } = value;`
    pub init: Option<Expr>,
    pub doc: Option<String>,
    pub span: Span,
}

impl PropertyDecl {
    pub fn is_auto(&self) -> bool {
        self.expr_body.is_none()
            && self.getter.as_ref().map_or(true, |g| g.body.is_none())
            && self.setter.as_ref().map_or(true, |s| s.body.is_none())
    }
    pub fn is_static(&self) -> bool {
        self.modifiers.contains(&Modifier::Static)
    }
}

#[derive(Debug, Clone)]
pub struct Accessor {
    /// `None` for auto-implemented accessors.
    pub body: Option<Block>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct MethodDecl {
    pub attrs: Vec<Attribute>,
    pub modifiers: Vec<Modifier>,
    pub ret: TypeRef,
    pub name: String,
    /// Generic parameters of `T Foo<T>(...)`; calls substitute them from type arguments.
    pub type_params: Vec<String>,
    pub params: Vec<Param>,
    /// `None` for abstract/extern methods.
    pub body: Option<Block>,
    pub doc: Option<String>,
    pub span: Span,
}

impl MethodDecl {
    pub fn has_attr(&self, name: &str) -> bool {
        self.attrs.iter().any(|a| a.name == name || a.name == format!("{}Attribute", name))
    }
    pub fn is_static(&self) -> bool {
        self.modifiers.contains(&Modifier::Static)
    }
    pub fn is_override(&self) -> bool {
        self.modifiers.contains(&Modifier::Override)
    }
    pub fn is_public(&self) -> bool {
        self.modifiers.contains(&Modifier::Public)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamMode {
    Value,
    Ref,
    Out,
    Params,
}

#[derive(Debug, Clone)]
pub struct Param {
    pub attrs: Vec<Attribute>,
    /// `this T x`: the first parameter of an extension method.
    pub this: bool,
    pub mode: ParamMode,
    pub ty: TypeRef,
    pub name: String,
    pub default: Option<Expr>,
    pub span: Span,
}

/// A syntactic type reference.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TypeRef {
    /// Simple or qualified name with optional generic args: `Foo`, `A.B.Foo`, `List<int>`.
    Named { name: String, args: Vec<TypeRef> },
    /// `T[]`, `T[,]` (rank), jagged arrays are nested.
    Array { elem: Box<TypeRef>, rank: u32 },
    /// `T?` nullable
    Nullable(Box<TypeRef>),
    /// `var`
    Var,
    Void,
}

impl TypeRef {
    pub fn named(name: &str) -> Self {
        TypeRef::Named { name: name.to_string(), args: vec![] }
    }
    pub fn is_var(&self) -> bool {
        matches!(self, TypeRef::Var)
    }
    pub fn is_void(&self) -> bool {
        matches!(self, TypeRef::Void)
    }
    /// Last segment of a qualified name, e.g. `VRC.SDKBase.VRCPlayerApi` → `VRCPlayerApi`.
    pub fn simple_name(&self) -> Option<&str> {
        match self {
            TypeRef::Named { name, .. } => Some(name.rsplit('.').next().unwrap_or(name)),
            _ => None,
        }
    }
    pub fn display(&self) -> String {
        match self {
            TypeRef::Named { name, args } => {
                if args.is_empty() {
                    name.clone()
                } else {
                    format!("{}<{}>", name, args.iter().map(|a| a.display()).collect::<Vec<_>>().join(", "))
                }
            }
            TypeRef::Array { elem, rank } => format!("{}[{}]", elem.display(), ",".repeat((*rank - 1) as usize)),
            TypeRef::Nullable(t) => format!("{}?", t.display()),
            TypeRef::Var => "var".into(),
            TypeRef::Void => "void".into(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum Stmt {
    Block(Block),
    Empty(Span),
    /// `T a = 1, b;` or `const T a = 1;`
    LocalDecl { ty: TypeRef, declarators: Vec<VarDeclarator>, is_const: bool, span: Span },
    Expr(Expr, Span),
    If { cond: Expr, then: Box<Stmt>, els: Option<Box<Stmt>>, span: Span },
    While { cond: Expr, body: Box<Stmt>, span: Span },
    DoWhile { body: Box<Stmt>, cond: Expr, span: Span },
    For { init: Vec<Stmt>, cond: Option<Expr>, update: Vec<Expr>, body: Box<Stmt>, span: Span },
    Foreach { ty: TypeRef, name: String, iter: Expr, body: Box<Stmt>, span: Span },
    Switch { subject: Expr, sections: Vec<SwitchSection>, span: Span },
    Break(Span),
    Continue(Span),
    Return(Option<Expr>, Span),
    Throw(Option<Expr>, Span),
    /// `try { } catch { } finally { }` — lowered as the try block only (with a warning).
    Try { body: Block, catches: Vec<Block>, finally: Option<Block>, span: Span },
    /// `lock (x) { }` — lowered as the body.
    Lock { body: Box<Stmt>, span: Span },
    /// `goto case X;` / `goto default;` inside a switch section.
    GotoCase(Option<Expr>, Span),
    /// `label:` — not supported, recorded for diagnostics.
    Label(String, Span),
    Goto(String, Span),
}

impl Stmt {
    pub fn span(&self) -> Span {
        match self {
            Stmt::Block(b) => b.span,
            Stmt::Empty(s) => *s,
            Stmt::LocalDecl { span, .. } => *span,
            Stmt::Expr(_, s) => *s,
            Stmt::If { span, .. } => *span,
            Stmt::While { span, .. } => *span,
            Stmt::DoWhile { span, .. } => *span,
            Stmt::For { span, .. } => *span,
            Stmt::Foreach { span, .. } => *span,
            Stmt::Switch { span, .. } => *span,
            Stmt::Break(s) | Stmt::Continue(s) => *s,
            Stmt::Return(_, s) | Stmt::Throw(_, s) => *s,
            Stmt::Try { span, .. } => *span,
            Stmt::Lock { span, .. } => *span,
            Stmt::GotoCase(_, s) => *s,
            Stmt::Label(_, s) | Stmt::Goto(_, s) => *s,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SwitchSection {
    /// Empty `labels` never happens; `default` is `SwitchLabel::Default`.
    pub labels: Vec<SwitchLabel>,
    pub body: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum SwitchLabel {
    Case(Expr),
    Default,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    And,
    Or,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    /// `??`
    Coalesce,
}

impl BinOp {
    pub fn is_comparison(self) -> bool {
        matches!(self, BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge)
    }
    pub fn is_arith(self) -> bool {
        matches!(self, BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem)
    }
    pub fn is_bitwise(self) -> bool {
        matches!(self, BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr)
    }
    pub fn as_str(self) -> &'static str {
        match self {
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Rem => "%",
            BinOp::And => "&&",
            BinOp::Or => "||",
            BinOp::BitAnd => "&",
            BinOp::BitOr => "|",
            BinOp::BitXor => "^",
            BinOp::Shl => "<<",
            BinOp::Shr => ">>",
            BinOp::Eq => "==",
            BinOp::Ne => "!=",
            BinOp::Lt => "<",
            BinOp::Le => "<=",
            BinOp::Gt => ">",
            BinOp::Ge => ">=",
            BinOp::Coalesce => "??",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnOp {
    Neg,
    Plus,
    Not,
    BitNot,
    PreInc,
    PreDec,
    PostInc,
    PostDec,
}

#[derive(Debug, Clone)]
pub enum Expr {
    Lit(Lit, Span),
    /// String interpolation: parts are either literal text or expressions with an optional format.
    Interp(Vec<InterpPiece>, Span),
    Ident(String, Span),
    This(Span),
    Base(Span),
    /// `target.name` (also `?.` when `null_cond`)
    Member { target: Box<Expr>, name: String, null_cond: bool, span: Span },
    /// `Foo<T>` generic name used as expression (only `GetComponent<T>` style calls)
    GenericName { name: Box<Expr>, args: Vec<TypeRef>, span: Span },
    /// A type used in expression position (`Vector3.zero`, casts). Only produced for builtin keyword types
    /// (`int.MaxValue`, `string.Empty`); other type names arrive as `Ident`.
    TypeExpr(TypeRef, Span),
    Call { callee: Box<Expr>, args: Vec<Arg>, span: Span },
    Index { target: Box<Expr>, indices: Vec<Expr>, null_cond: bool, span: Span },
    Unary { op: UnOp, expr: Box<Expr>, span: Span },
    Binary { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr>, span: Span },
    /// `lhs = rhs` or compound `lhs op= rhs` (`op` is `Some`)
    Assign { op: Option<BinOp>, lhs: Box<Expr>, rhs: Box<Expr>, span: Span },
    Cond { cond: Box<Expr>, then: Box<Expr>, els: Box<Expr>, span: Span },
    Cast { ty: TypeRef, expr: Box<Expr>, span: Span },
    Is { expr: Box<Expr>, ty: TypeRef, span: Span },
    As { expr: Box<Expr>, ty: TypeRef, span: Span },
    New { ty: TypeRef, args: Vec<Arg>, init: Option<Vec<Expr>>, span: Span },
    /// `new T[n]`, `new T[] { ... }`, `new T[n, m]`
    NewArray { elem: TypeRef, sizes: Vec<Option<Expr>>, rank: u32, init: Option<Vec<Expr>>, span: Span },
    /// `{ a, b, c }` array initializer in a declaration context
    ArrayInit(Vec<Expr>, Span),
    Typeof(TypeRef, Span),
    Nameof(Box<Expr>, Span),
    Default(Option<TypeRef>, Span),
    Paren(Box<Expr>, Span),
    /// `checked(expr)` / `unchecked(expr)`
    Checked(Box<Expr>, bool, Span),
    /// Lambda — not supported by Udon but parsed to give a clear diagnostic.
    Lambda { params: Vec<String>, body: Box<LambdaBody>, span: Span },
}

#[derive(Debug, Clone)]
pub enum LambdaBody {
    Expr(Expr),
    Block(Block),
}

#[derive(Debug, Clone)]
pub enum InterpPiece {
    Text(String),
    Expr { expr: Expr, format: Option<String> },
}

#[derive(Debug, Clone)]
pub struct Arg {
    pub name: Option<String>,
    pub mode: ParamMode,
    /// `out var x` / `out T x` declaration in argument position
    pub out_decl: Option<(TypeRef, String)>,
    pub expr: Expr,
}

impl Expr {
    pub fn span(&self) -> Span {
        match self {
            Expr::Lit(_, s)
            | Expr::Interp(_, s)
            | Expr::Ident(_, s)
            | Expr::This(s)
            | Expr::Base(s)
            | Expr::TypeExpr(_, s)
            | Expr::ArrayInit(_, s)
            | Expr::Typeof(_, s)
            | Expr::Nameof(_, s)
            | Expr::Default(_, s)
            | Expr::Paren(_, s)
            | Expr::Checked(_, _, s) => *s,
            Expr::Member { span, .. }
            | Expr::GenericName { span, .. }
            | Expr::Call { span, .. }
            | Expr::Index { span, .. }
            | Expr::Unary { span, .. }
            | Expr::Binary { span, .. }
            | Expr::Assign { span, .. }
            | Expr::Cond { span, .. }
            | Expr::Cast { span, .. }
            | Expr::Is { span, .. }
            | Expr::As { span, .. }
            | Expr::New { span, .. }
            | Expr::NewArray { span, .. }
            | Expr::Lambda { span, .. } => *span,
        }
    }

    /// Strip parentheses.
    pub fn unparen(&self) -> &Expr {
        match self {
            Expr::Paren(e, _) => e.unparen(),
            e => e,
        }
    }

    /// If this expression is a (possibly qualified) name, return its dotted path.
    pub fn as_dotted_name(&self) -> Option<String> {
        match self.unparen() {
            Expr::Ident(n, _) => Some(n.clone()),
            Expr::Member { target, name, null_cond: false, .. } => {
                target.as_dotted_name().map(|t| format!("{}.{}", t, name))
            }
            Expr::TypeExpr(t, _) => Some(t.display()),
            _ => None,
        }
    }
}
