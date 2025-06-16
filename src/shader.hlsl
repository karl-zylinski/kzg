cbuffer constant_buffer : register(b0) {
	float4x4 view_matrix;
};

struct UI_Element {
	float2 pos;
	float2 size;
	float4 color;
};

StructuredBuffer<UI_Element> ui_elements : register(t0);

struct PS_Input {
	float4 position : SV_POSITION;
	float4 color : COLOR;
};

struct Element_Index {
	uint idx    : 24;
	uint corner : 8;
};

PS_Input VSMain(uint v : SV_VertexID) {
	Element_Index ei = (Element_Index)v;
	uint idx = ei.idx;
	UI_Element e = ui_elements[idx];
	uint corner = ei.corner;
	float2 pos = e.pos;

	switch (corner) {
	case 0: break;
	case 1: pos += float2(e.size.x, 0); break;
	case 2: pos += e.size; break;
	case 3: pos += float2(0, e.size.y); break;
	}

	PS_Input result;
	result.position = mul(float4(pos, 0, 1), view_matrix);
	result.color = e.color;
	return result;
}

float4 PSMain(PS_Input input) : SV_TARGET {
	return input.color;
};