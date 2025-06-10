cbuffer ConstantBuffers : register(b0) {
	float4x4 mvp;
};

struct UI_Element {
	float2 pos;
	float2 size;
	float4 color;
};

StructuredBuffer<UI_Element> ui_elements : register(t0);

struct PSInput {
	float4 position : SV_POSITION;
	float4 color : COLOR;
};

PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0, uint v : SV_VertexID) {
	PSInput result;
	uint idx = 0b00000000111111111111111111111111 & v;
	UI_Element e = ui_elements[idx];
	uint corner = v >> 24;
	float2 pos = e.pos;

	switch (corner) {
	case 0: break;
	case 1: pos += float2(e.size.x, 0); break;
	case 2: pos += e.size; break;
	case 3: pos += float2(0, e.size.y); break;
	}

	result.position = mul(float4(pos, 0, 1), mvp);
	result.color = e.color;
	return result;
}
float4 PSMain(PSInput input) : SV_TARGET {
	return input.color;
};