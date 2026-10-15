--!strict
-- Pure-Lua builders for the view nodes the sidebar sends with cx.canvas:open/set. Each returns the
-- same table as the tern.ui builder of the same name: a TSP node `{k = kind, p = props, c =
-- children}` with empty props and children left out, `el` adding `tag` and `row`/`col` adding
-- `gap = "sm"`. tern.ui copies a node's whole subtree through native code on every call, so a
-- sidebar costs time in proportion to its size times its depth: 15-30 ms of the window's 50 ms
-- hook budget with six hosts, and Tern disables a hook that overruns it until the plugin reloads.
-- Props and child lists are copied shallowly; nested tables are shared, so finish a node before
-- adding it to a parent.

export type Span = { t: string, s: string? }
export type Spans = { Span | string } | Span | string
export type Node = {
	k: string,
	p: { [string]: any }?,
	c: { Node }?,
}

local function props(p: { [string]: any }?): { [string]: any }?
	return if p and next(p) ~= nil then table.clone(p) else nil
end

local function children(c: { Node }?): { Node }?
	return if c and #c > 0 then table.clone(c) else nil
end

local function node(kind: string, p: { [string]: any }?, c: { Node }?): Node
	return { k = kind, p = props(p), c = children(c) }
end

local function el(tag: string, p: { [string]: any }?, c: { Node }?): Node
	local copied: { [string]: any } = if p then table.clone(p) else {}
	copied.tag = tag
	return { k = "el", p = copied, c = children(c) }
end

local function span(t: string, s: string?): Span
	return { t = t, s = s }
end

local function text(spans: Spans): Node
	local list: { Span } = {}
	if type(spans) == "string" then
		list[1] = { t = spans }
	elseif (spans :: any).t ~= nil then
		list[1] = spans :: Span
	else
		for _, part in spans :: { Span | string } do
			table.insert(list, if type(part) == "string" then { t = part } else part)
		end
	end
	return { k = "text", p = { spans = list } }
end

local function row(c: { Node }): Node
	return { k = "row", p = { gap = "sm" }, c = children(c) }
end

local function col(c: { Node }): Node
	return { k = "col", p = { gap = "sm" }, c = children(c) }
end

local function badge(t: string, tone: string): Node
	return { k = "badge", p = { text = t, tone = tone } }
end

return {
	node = node,
	el = el,
	span = span,
	text = text,
	row = row,
	col = col,
	badge = badge,
}
