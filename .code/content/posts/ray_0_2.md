---
title: Ray 0.2.0
now: Fri Aug 19 23:48:31 2011
---

Hey and happy Whynight (at least, I can guarantee it is not day here),

Here's a new version of my ruby game library — fixing bugs that I had not met,
adding new fun features, and improving the internals. Here's a list of those new
features. :)

It can still be installed with just ``gem install ray``.

Shader generation
-----------------

Shaders are very useful, but they're not written in Ruby. Having a DSL to
generate them would help. Here's what I have com up with:

    effect_generator { |gen|
      gen << grayscale
    }.build(window.shader)
{:.ruby}

The above code compiles a fragment shader to render images in shades of
gray. The output isn't quite as efficient as a hand-written shader, but it's
quite readable:

    #version 110

    varying vec4 var_Color;
    varying vec2 var_TexCoord;

    uniform sampler2D in_Texture;
    uniform bool in_TextureEnabled;


    /* Headers */


    /* Structs */

    struct ray_grayscale {
      bool enabled;
      vec3 ratio;
    };

    /* Effects parameters */
    uniform ray_grayscale grayscale;

    /* Functions */
    vec4 do_grayscale(ray_grayscale args, vec4 color) {
      float gray = dot(color.rgb, args.ratio);
      return vec4(gray, gray, gray, color.a);
    }

    void main() {
      /* Apply default value */
      vec4 color;
      if (in_TextureEnabled)
        color = texture2D(in_Texture, var_TexCoord) * var_Color;
      else
        color = var_Color;

      if (grayscale.enabled)
        color = do_grayscale(grayscale, color);

      gl_FragColor = color;
    }
 {:.c}

 There aren't many effects in Ray yet, but it's easy to write one in a few lines
 of code (even though there needs to be GLSL code there).

Better control over OpenGL contexts
-----------------------------------

The OpenGL context can now be configured before it is created. This allows to
ask Ray to use the OpenGL core profile for instance, which is, on some platforms
(say, Mac OS X), the only way to get OpenGL 3.

You can also debug OpenGL calls — which is something quite useful for me at
least:

    Ray::GL.debug = true
    Ray::GL.callback = proc do |source, type, _, severity, msg|
      puts "[#{source}][#{type}][#{severity}] #{msg}"
    end
{:.ruby}

Geometry instancing
-------------------

Something useful when playing with OpenGL and Ray, you can use OpenGL's geometry
instancing (assuming it is available) to render similar objects many times —
like, drawing an army of cubes.

Faster pixel copies
-------------------

Ray can now use OpenGL's features to copy pixels asynchronously, just in case
you'd need to copy images often (either from another image or from the
framebuffer):

     bus = Ray::PixelBus.new 1024 # can store 1024 pixels (4KB)
     bus.pull window
     bus.push image

     copy = bus.copy image
{:.ruby}

Lower-level OpenGL access
-------------------------

You can now access the ID of (some) OpenGL objects created by Ray. This is
useful to play with OpenGL, and also (and that's actually the reason I added
this) OpenCL, which can use OpenGL's textures and buffers.

Screenshot!
-----------

Here's an actual game written with Ray,
[Zed and Ginger](https://github.com/Spooner/zed_and_ginger):

![Z&G](http://f.cl.ly/items/2h2W3I3a3M1M0Q142B3l/zed_and_ginger_17-2-player-cameras_small.png)


