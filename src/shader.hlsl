cbuffer ConstantBuffers : register(b0) {
	float4x4 mvp;
	float nums[64];
};

/*struct UI_Element {
	float2 pos;
	float2 size;
};*/

//ConstantBuffer<UI_Element> ui_elements : register(b1);

struct PSInput {
	float4 position : SV_POSITION;
	float4 color : COLOR;
};
PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0, uint v : SV_VertexID) {
	PSInput result;

	if (v == 10) {
		position = float4(0, nums[v-10], 0, 1);
	}

	result.position = mul(position, mvp);


	result.color = color;
	return result;
}
float4 PSMain(PSInput input) : SV_TARGET {
	return input.color;
};