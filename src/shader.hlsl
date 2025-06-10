cbuffer ConstantBuffers : register(b0) {
	float4x4 mvp;
};

struct UI_Element {
	float2 pos;
	float2 size;
};

StructuredBuffer<UI_Element> ui_elements : register(t0);

struct PSInput {
	float4 position : SV_POSITION;
	float4 color : COLOR;
};

PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0, uint v : SV_VertexID) {
	PSInput result;
	float4 pos = float4(ui_elements[v].pos, 0, 1);
	result.position = mul(pos, mvp);
	result.color = color;
	return result;
}
float4 PSMain(PSInput input) : SV_TARGET {
	return input.color;
};