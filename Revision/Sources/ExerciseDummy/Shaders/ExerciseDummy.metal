#include <metal_stdlib>
using namespace metal;

struct Vertex {
    packed_float3 position;
    packed_float3 normal;
    uchar4 joints;
    uchar4 weights;
    uint group, reserved;
};
struct Scene {
    float4x4 vp, lightVP;
    float4 right, up, back, center, key;
    float4 shadows[4]; // contact center in world xyz, radius in meters
    float4 sideWeights, passiveMuscle;
};
struct Surface {
    float4 position [[position]];
    float3 world, normal;
    float4 material;
    float visibility;
};
float4x4 skinMatrix(Vertex v, const device float4x4 *joints) {
    if (v.weights.x == 255) return joints[v.joints.x];
    float4 w = float4(v.weights) / 255.0;
    float4x4 t = joints[v.joints.x] * w.x + joints[v.joints.y] * w.y;
    if (v.weights.z != 0) t += joints[v.joints.z] * w.z;
    if (v.weights.w != 0) t += joints[v.joints.w] * w.w;
    return t;
}
vertex float4 shadowVertex(uint id [[vertex_id]],
                           const device Vertex *mesh [[buffer(0)]],
                           constant Scene &s [[buffer(1)]],
                           const device float4x4 *joints [[buffer(2)]]) {
    Vertex v = mesh[id];
    return s.lightVP * (skinMatrix(v,joints) * float4(float3(v.position),1));
}
float lightVisibility(float3 p, constant Scene &s, depth2d<float> shadow) {
    float3 sc = (s.lightVP*float4(p,1)).xyz;
    float2 uv = sc.xy*float2(0.5,-0.5)+0.5;
    if (any(uv<0.0) || any(uv>1.0) || sc.z<=0.0 || sc.z>=1.0) return 1.0;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
    float radius = 1.35 / float(shadow.get_width());
    float result = 0;
    for (int i=-1;i<=1;i++)
        for (int j=-1;j<=1;j++)
            result += shadow.sample_compare(smp,uv+radius*float2(i,j),sc.z-0.0015);
    return result/9.0;
}
vertex Surface bodyVertex(uint id [[vertex_id]],
                          const device Vertex *mesh [[buffer(0)]],
                          constant Scene &s [[buffer(1)]],
                          const device float4x4 *joints [[buffer(2)]],
                          const device float4 *palette [[buffer(3)]]) {
    Vertex v = mesh[id];
    float4x4 t = skinMatrix(v,joints);
    float4 world = t * float4(float3(v.position),1);
    // Cofactor columns give the inverse-transpose normal direction under weighted
    // skinning and under the nonuniform scaling of authored equipment transforms.
    float3 a = t[0].xyz, b = t[1].xyz, c = t[2].xyz;
    float3x3 normalMatrix(cross(b,c), cross(c,a), cross(a,b));
    Surface out;
    out.position = s.vp * world;
    out.world = world.xyz;
    out.normal = normalMatrix * float3(v.normal) * (dot(a,cross(b,c)) < 0 ? -1.0 : 1.0);
    float4 material = palette[v.group];
    if (material.w < 0) {
        float fraction = 1.0;
        if (material.w < -2.0) {
            fraction = mix(s.sideWeights.y,s.sideWeights.x,smoothstep(-0.01,0.01,v.position.x));
            material.w += 2.0;
        }
        material.rgb = mix(s.passiveMuscle.rgb, material.rgb, fraction);
    }
    material.w = abs(material.w);
    out.material = material;
    uint baked = v.reserved & 255u;
    out.visibility = baked == 0u ? 1.0 : float(baked-1u)/254.0;
    return out;
}
fragment float4 bodyFragment(Surface in [[stage_in]], constant Scene &s [[buffer(1)]], depth2d<float> shadow [[texture(0)]]) {
    float3 n = normalize(in.normal), v = s.back.xyz;
    float3 key = s.key.xyz;
    float3 fill = normalize(0.7*s.right.xyz + 0.3*float3(0,1,0) + 0.43*v);
    float lambert = max(dot(n,key),0.0);
    float wrap = clamp(0.28 + 0.72*dot(n,fill),0.0,1.0);
    float sky = 0.5+0.5*n.y;
    float ambient = (0.25 + 0.14*sky + 0.12*wrap) * mix(0.48,1.0,in.visibility);
    float direct = 0.76*lambert * mix(0.78,1.0,in.visibility);
    direct *= mix(0.60,1.0,lightVisibility(in.world,s,shadow));
    float3 color = in.material.rgb * (ambient + direct);
    float spec = pow(max(dot(n,normalize(key+v)),0.0),36.0);
    color += in.material.w*(0.13*spec + 0.045*pow(1.0-abs(dot(n,v)),3.0));
    return float4(color,1);
}
struct Background { float4 position [[position]]; float2 uv; };
vertex Background stageVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id<<1)&2,id&2);
    return {float4(uv*2.0-1.0,0.999,1), uv*2.0-1.0};
}
struct Ground { float4 color [[color(0)]]; float depth [[depth(any)]]; };
fragment Ground stageFragment(Background in [[stage_in]], constant Scene &s [[buffer(1)]], depth2d<float> shadow [[texture(0)]]) {
    float2 uv = in.uv;
    float depth = 1.0;
    float3 base = mix(float3(0.032,0.043,0.061),float3(0.064,0.081,0.104),clamp(0.45 - uv.y*0.26,0.0,1.0));
    float3 rayOrigin = s.center.xyz + s.right.xyz*(uv.x*s.right.w) + s.up.xyz*(uv.y*s.up.w) + s.back.xyz*8.0;
    if (s.back.y > 0.0001) {
        float t = rayOrigin.y/s.back.y;
        float3 hit = rayOrigin - s.back.xyz*t;
        float2 floorAt = hit.xz;
        if (t > 0.0) {
            depth = clamp((s.vp * float4(hit,1)).z + 0.0004,0.0,1.0);
            float fade = exp(-0.48*length(floorAt - s.center.xz));
            float2 grid = abs(fract(floorAt*2.0+0.5)-0.5) / max(fwidth(floorAt*2.0),float2(0.001));
            base += 0.008*(1.0-min(min(grid.x,grid.y),1.0))*fade;
            float occlusion = 0.0;
            for (uint i=0;i<4;i++) {
                float4 p = s.shadows[i];
                float h = max(0.0,p.y);
                float radius = max(p.w + h*0.22,0.001);
                float2 d = (floorAt-p.xz)/radius;
                occlusion += 0.46*exp(-dot(d,d))*exp(-h*4.0);
            }
            base *= (1.0-clamp(occlusion,0.0,0.68)) * mix(0.44,1.0,lightVisibility(hit,s,shadow));
        }
    }
    return {float4(base,1), depth};
}
