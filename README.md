# BetterImports

A free Roblox Studio plugin that fixes freshly imported meshes.

You import a batch from Blender, Kenney or Quaternius, press Play, and the whole thing
falls through the world. Or `PivotTo` lays a building on its side. Or you publish and ship
a map full of loose geometry nobody noticed. BetterImports finds all of that in one scan
and fixes it in one click, inside a single undo step.

![toolbar: Imports](docs/toolbar.png)

## What it checks

Every one of these is a real failure that costs real hours.

| Check | Why it matters |
|---|---|
| **Unanchored** | Imports arrive `Anchored = false`. A 1,700-stud part falls the instant you press Play and drags the physics solver with it. |
| **Rotated PivotOffset** | Blender is Z-up, Roblox is Y-up, so every imported MeshPart gets a PivotOffset rotated 90° about X. `Model:PivotTo` then lays it on its side and you spend an hour blaming your export. |
| **Model without a PrimaryPart** | `PivotTo` and `GetPivot` misbehave without one. |
| **Collidable scenery** | A 1.78-stud bollard is exactly the height a humanoid snags on instead of stepping over. |
| **CanQuery on** | Raycasts and the camera popper hit scenery the player cannot see. |
| **Casting shadows** | The largest avoidable render cost on a phone. Moving decor that casts shadows invalidates the shadow map every frame. |
| **Expensive CollisionFidelity** | The default builds a full mesh collider for props nobody can touch. `Box` is almost always right for scenery. |
| **Loose in Workspace** | Imports land at the top of Workspace and are genuinely easy to publish by accident. |

Plus two actions:

- **Scale to height** — type the height in studs you want and every selected root is scaled
  to it. Quaternius kits land about 50× too big, Kenney about 100×, and the right number is
  never the one in the importer.
- **Move to `ReplicatedStorage/Imports`** or `ServerStorage/Imports`, so nothing is left
  sitting in Workspace.

## Install

**From source:**

```
git clone https://github.com/itwillystyle/better-imports
cd better-imports
python build.py
```

That writes `BetterImports.rbxmx` and copies it into your Studio plugins folder
(`%LOCALAPPDATA%\Roblox\Plugins` on Windows). Restart Studio, or open
Plugins → Manage Plugins.

**Manually:** download `BetterImports.rbxmx` from Releases and drop it in that same folder.

## Use

1. Select your freshly imported batch (or press **Scan Workspace** to look at everything).
2. Read the list. Rows with nothing to fix are dimmed.
3. Tick the checks you want. Anchor, pivot and PrimaryPart are on by default because they
   are almost always right. Collision, query, shadow and fidelity are off by default
   because they depend on whether the thing is scenery or not.
4. Optionally type a target height, and pick where it should end up.
5. **Fix**. One `Ctrl+Z` undoes all of it.

## Scale is absolute, not relative

Worth saying because it is the easiest thing to get wrong when writing this yourself:
`Model:ScaleTo` sets an **absolute** scale, it does not multiply the current one. To make a
model 34 studs tall you want

```lua
local _, size = model:GetBoundingBox()
model:ScaleTo(model:GetScale() * (34 / size.Y))
```

not `model:ScaleTo(34 / size.Y)`.

## Safety

- Every fix runs inside one `ChangeHistoryService` recording, so `Ctrl+Z` reverts the whole
  operation rather than one property at a time.
- Nothing is deleted. The only thing that moves is what you explicitly ask to move.
- Each fix is wrapped in `pcall`, and anything that fails is counted and reported rather
  than silently skipped.

## Licence

MIT. Use it, fork it, ship it.
