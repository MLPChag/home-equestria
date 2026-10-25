// RGB is a low-frequency ground palette; A says whether vegetation has support.
global uniform sampler2D vegetation_color_map : source_color, filter_linear, repeat_disable;
global uniform vec4 vegetation_color_rect;
global uniform bool vegetation_color_enabled;
vec4 vegetation_ground(vec2 position) {
    if (!vegetation_color_enabled) return vec4(0.0);
    vec2 uv=(position-vegetation_color_rect.xy+vec2(8.0))/vegetation_color_rect.zw;
    if (any(lessThan(uv,vec2(0.0))) || any(greaterThan(uv,vec2(1.0)))) return vec4(0.0);
    return textureLod(vegetation_color_map,uv,0.0);
}
float vegetation_green_mask(vec3 sample_rgb) {
    vec3 chroma=sample_rgb/max(max(sample_rgb.r,max(sample_rgb.g,sample_rgb.b)),.0001);
    return smoothstep(.015,.16,chroma.g-chroma.r)*smoothstep(.02,.20,chroma.g-chroma.b);
}
// Seasons (world/weather/seasons.gd): rgb = leaf colour the season turns green leaves
// toward (value kept), a = how far; snow dusts every leaf a little in winter.
global uniform vec4 season_leaf;
global uniform float season_snow;
vec3 vegetation_hue(vec3 authored,vec4 ground,float strength) {
    // Preserve source shading/detail; change chroma without flattening leaf value.
    vec3 luma=vec3(.2126,.7152,.0722);
    vec3 matched=ground.rgb*(dot(authored,luma)/max(dot(ground.rgb,luma),.00001));
    vec3 c=mix(authored,matched,clamp(strength*ground.a,0.0,1.0));
    float green=vegetation_green_mask(authored);
    vec3 turned=season_leaf.rgb*(dot(c,luma)/max(dot(season_leaf.rgb,luma),.00001));
    c=mix(c,turned,clamp(season_leaf.a*green,0.0,1.0));
    return mix(c,vec3(.92,.94,.98),season_snow*.22);
}
