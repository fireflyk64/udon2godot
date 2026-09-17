//! udon2godot — converts UdonSharp (VRChat Udon C#) scripts into SafeGDScript (`.sgd`)
//! for the Godot Sandbox (libriscv/godot-sandbox).

pub mod api;
pub mod ast;
pub mod diag;
pub mod externs;
pub mod gd;
pub mod lexer;
pub mod lower;
pub mod names;
pub mod nullflow;
pub mod parser;
pub mod program;
pub mod summary;
pub mod template;
pub mod token;
pub mod types;
