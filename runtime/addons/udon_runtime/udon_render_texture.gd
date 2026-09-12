## A Unity RenderTexture asset. Godot renders to viewports, which must live in the scene tree, so
## the texture is a description; `U.rt_viewport(rt)` creates (once) the SubViewport that backs it
## and `U.rt_texture(rt)` returns the ViewportTexture to put on materials and UI.
@tool
class_name UdonRenderTexture
extends Resource

@export var width: int = 256
@export var height: int = 256
@export var depth: int = 24
@export var transparent: bool = true
