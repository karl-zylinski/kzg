package kzg

cut_rect_top :: proc(r: ^Rect, y: f32, m: f32) -> Rect {
	res := r^
	res.y += m
	res.h = y
	r.y += y + m
	r.h -= y + m
	return res
}

cut_rect_bottom :: proc(r: ^Rect, h: f32, m: f32) -> Rect {
	res := r^
	res.h = h
	res.y = r.y + r.h - h - m
	r.h -= h + m
	return res
}

cut_rect_left :: proc(r: ^Rect, x, m: f32) -> Rect {
	res := r^
	res.x += m
	res.w = x
	r.x += x + m
	r.w -= x + m
	return res
}

cut_rect_right :: proc(r: ^Rect, w, m: f32) -> Rect {
	res := r^
	res.w = w
	res.x = r.x + r.w - w - m
	r.w -= w + m
	return res
}

split_rect_top :: proc(r: Rect, y: f32, m: f32) -> (top, bottom: Rect) {
	top = r
	bottom = r
	top.y += m
	top.h = y
	bottom.y += y + m
	bottom.h -= y + m
	return
}

split_rect_left :: proc(r: Rect, x: f32, m: f32) -> (left, right: Rect) {
	left = r
	right = r
	left.w = x
	right.x += x + m
	right.w -= x +m
	return
}

split_rect_bottom :: proc(r: Rect, y: f32, m: f32) -> (top, bottom: Rect) {
	top = r
	top.h -= y + m
	bottom = r
	bottom.y = top.y + top.h + m
	bottom.h = y
	return
}

split_rect_right :: proc(r: Rect, x: f32, m: f32) -> (left, right: Rect) {
	left = r
	right = r
	right.w = x
	left.w -= x + m
	right.x = left.x + left.w
	return
}


