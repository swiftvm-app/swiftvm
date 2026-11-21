#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <stdio.h>
#include <stdlib.h>

#include "tgsi/tgsi_text.h"
#include "vrend/vrend_shader.h"

// These test shader translation and GPU results; no guest or window is needed.
/* Run from the repository root after scripts/build-qemu.sh:
 *
 * task_root=$PWD
 * task_virgl=$task_root/.build/qemu/sources/virglrenderer
 * task_prefix=$task_root/.build/qemu/prefix
 * cd "$task_virgl"
 * clang -std=c11 -Wall -Wextra -Werror -include build/config.h -DHAVE_CONFIG_H=1 \
 *   -I. -Ibuild -Ibuild/src -Isrc -Isrc/gallium/include -Isrc/gallium/auxiliary \
 *   -Ibuild/src/gallium -Isrc/mesa -Isrc/mesa/pipe -Isrc/mesa/compat -Isrc/mesa/util \
 *   -I"$task_prefix/include" "$task_root/Tests/Native/VirglShaderTests.c" \
 *   build/src/libvirgl.a build/src/gallium/libgallium.a build/src/mesa/libmesa.a \
 *   -L"$task_prefix/lib" -lepoxy -framework Metal -framework Foundation \
 *   -Wl,-rpath,"$task_prefix/lib" -o /tmp/swiftvm-virgl-shader-tests
 * /tmp/swiftvm-virgl-shader-tests
 */
static void require(bool condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static GLuint compile(GLenum type, GLsizei count, const char **source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, count, source, NULL);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[4096];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "%s\n", log);
    }
    require(compiled, "translated shader compiles on ANGLE");
    return shader;
}

static GLuint translate_fragment(const char *tgsi, unsigned buffers)
{
    struct tgsi_token tokens[256];
    require(tgsi_text_translate(tgsi, tokens, 256), "parse fragment program");
    struct vrend_shader_cfg config = {
        .glsl_version = 300,
        .max_draw_buffers = buffers,
        .use_gles = true,
        .has_dual_src_blend = true,
    };
    struct vrend_shader_key key = {0};
    struct vrend_shader_info info = {0};
    struct vrend_variable_shader_info variables = {0};
    struct vrend_strarray strings = {0};
    require(strarray_alloc(&strings, SHADER_MAX_STRINGS), "allocate shader strings");
    require(vrend_convert_shader(NULL, &config, tokens, 0, &key, &info, &variables, &strings),
            "translate guest fragment program");
    const char *source[SHADER_MAX_STRINGS];
    for (int i = 0; i < strings.num_strings; i++) source[i] = strings.strings[i].buf;
    GLuint shader = compile(GL_FRAGMENT_SHADER, strings.num_strings, source);
    strarray_free(&strings, true);
    free(info.sampler_arrays);
    free(info.image_arrays);
    return shader;
}

static GLuint fragment(bool dual, bool broadcast, bool depth, unsigned buffers)
{
    char tgsi[1024];
    snprintf(tgsi, sizeof(tgsi),
             "FRAG\n%s"
             "DCL OUT[0], COLOR[0]\n%s%s"
             "IMM[0] FLT32 {0.25, 0.5, 0.75, 1.0}\n"
             "IMM[1] FLT32 {0.5, 0.5, 0.5, 0.5}\n"
             "MOV OUT[0], IMM[0]\n%s%sEND\n",
             broadcast ? "PROPERTY FS_COLOR0_WRITES_ALL_CBUFS 1\n" : "",
             dual ? "DCL OUT[1], COLOR[1]\n" : "",
             depth ? "DCL OUT[2], POSITION\n" : "",
             dual ? "MOV OUT[1], IMM[1]\n" : "",
             depth ? "MOV OUT[2].z, IMM[1].xxxx\n" : "");
    return translate_fragment(tgsi, buffers);
}

static void check_blending(GLuint vertex, bool dual, bool broadcast, bool depth, unsigned buffers)
{
    printf("dual=%d broadcast=%d depth=%d buffers=%u\n", dual, broadcast, depth, buffers);
    GLuint shader = fragment(dual, broadcast, depth, buffers);
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, shader);
    if (dual) {
        // The same link-time bindings as vrend_renderer.c. Both blend sources go to target zero.
        glBindFragDataLocationIndexedEXT(program, 0, 0, "fsout_c0");
        glBindFragDataLocationIndexedEXT(program, 0, 1, "fsout_c1");
    }
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[4096];
        glGetProgramInfoLog(program, sizeof(log), NULL, log);
        fprintf(stderr, "%s\n", log);
    }
    require(linked, "translated fragment outputs link");
    if (dual) {
        require(glGetFragDataLocation(program, "fsout_c0") == 0 &&
                glGetFragDataLocation(program, "fsout_c1") == 0 &&
                glGetFragDataIndexEXT(program, "fsout_c0") == 0 &&
                glGetFragDataIndexEXT(program, "fsout_c1") == 1,
                "both blend sources bind to target zero with distinct source indices");
    }

    GLuint framebuffer, textures[4];
    GLenum attachments[4];
    unsigned targets = dual ? 1 : buffers;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glGenTextures(targets, textures);
    for (unsigned i = 0; i < targets; i++) {
        attachments[i] = GL_COLOR_ATTACHMENT0 + i;
        glBindTexture(GL_TEXTURE_2D, textures[i]);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 1, 1);
        glFramebufferTexture2D(GL_FRAMEBUFFER, attachments[i], GL_TEXTURE_2D, textures[i], 0);
    }
    glDrawBuffers(targets, attachments);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "complete render targets");
    glViewport(0, 0, 1, 1);
    glClearColor(1, 1, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (dual) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC1_COLOR_EXT, GL_ONE_MINUS_SRC1_COLOR_EXT);
    } else {
        glDisable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ZERO);
    }
    glUseProgram(program);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    for (unsigned i = 0; i < targets; i++) {
        GLubyte sample[4];
        const int *expected = dual ? (int[]){159, 191, 223, 255} : (int[]){64, 128, 191, 255};
        glReadBuffer(attachments[i]);
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, sample);
        require(glGetError() == GL_NO_ERROR, "draw and readback succeed");
        for (unsigned channel = 0; channel < 4; channel++) {
            require(abs((int)sample[channel] - expected[channel]) <= 1,
                    dual ? "secondary source controls blending" : "color broadcasts to every render target");
        }
    }
    glUseProgram(0);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(targets, textures);
    glDeleteProgram(program);
    glDeleteShader(shader);
}

static void check_integer_selection(GLuint vertex)
{
    // Small integers occupy subnormal float bit patterns in TGSI registers.
    // UCMP must preserve those bits, ordinary float payloads, and the sign bit.
    const char *tgsi =
        "FRAG\n"
        "DCL CONST[0..1]\n"
        "DCL OUT[0], COLOR\n"
        "DCL TEMP[0..1]\n"
        "IMM[0] UINT32 {4, 16, 2147483648, 1056964608}\n"
        "IMM[1] UINT32 {16, 4, 305419896, 1073741824}\n"
        "UCMP TEMP[0].x, CONST[0], IMM[0], IMM[1]\n"
        "UCMP TEMP[0].yzw, CONST[0], IMM[0], IMM[1]\n"
        "USEQ TEMP[1], TEMP[0], CONST[1]\n"
        "U2F OUT[0], TEMP[1]\n"
        "END\n";
    GLuint shader = translate_fragment(tgsi, 1);
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, shader);
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    require(linked, "integer-selection program links");
    glUseProgram(program);
    GLint constants = glGetUniformLocation(program, "fsconst0[0]");
    require(constants >= 0, "selection inputs remain dynamic");

    GLuint framebuffer, texture;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 1, 1);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "complete selection render target");
    glViewport(0, 0, 1, 1);
    glDisable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ZERO);
    const GLuint conditions[][4] = {
        {0, 0, 0, 0},
        {1, 1, 1, 1},
        {0, 0x80000000U, 0, 0xffffffffU},
        {0xffffffffU, 0, 0x80000000U, 0},
    };
    const GLuint sources[][4] = {
        {4, 16, 0x80000000U, 0x3f000000U},
        {16, 4, 0x12345678U, 0x40000000U},
    };
    for (unsigned i = 0; i < sizeof(conditions) / sizeof(conditions[0]); ++i) {
        GLuint values[8];
        for (unsigned channel = 0; channel < 4; ++channel) {
            values[channel] = conditions[i][channel];
            values[4 + channel] = sources[conditions[i][channel] ? 0 : 1][channel];
        }
        glUniform4uiv(constants, 2, values);
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        GLubyte sample[4];
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, sample);
        require(glGetError() == GL_NO_ERROR, "integer selection draw and readback succeed");
        for (unsigned channel = 0; channel < 4; ++channel) {
            require(sample[channel] == 255, "UCMP preserves selected register bits for every component");
        }
    }
    glUseProgram(0);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    glDeleteProgram(program);
    glDeleteShader(shader);
    puts("Integer selection tests passed (4 cases).");
}

int main(void)
{
    const EGLint display_attributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE,
    };
    EGLDisplay display = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, NULL, display_attributes);
    require(display != EGL_NO_DISPLAY && eglInitialize(display, NULL, NULL), "initialize ANGLE Metal display");
    require(eglBindAPI(EGL_OPENGL_ES_API), "select GLES");
    const EGLint attributes[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE,
    };
    EGLConfig config;
    EGLint count;
    require(eglChooseConfig(display, attributes, &config, 1, &count) && count == 1, "choose GLES configuration");
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    require(context != EGL_NO_CONTEXT, "create GLES context");
    const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attributes);
    require(surface != EGL_NO_SURFACE && eglMakeCurrent(display, surface, surface, context), "make GLES context current");
    require(epoxy_has_gl_extension("GL_EXT_blend_func_extended"), "dual-source blending is available");
    printf("Renderer: %s\n", glGetString(GL_RENDERER));
    const char *vertex_source =
        "#version 300 es\n"
        "void main() {\n"
        "vec2 positions[3] = vec2[3](vec2(-1, -1), vec2(3, -1), vec2(-1, 3));\n"
        "gl_Position = vec4(positions[gl_VertexID], 0, 1);\n}\n";
    GLuint vertex = compile(GL_VERTEX_SHADER, 1, &vertex_source);
    GLuint array;
    glGenVertexArrays(1, &array);
    glBindVertexArray(array);
    for (unsigned depth = 0; depth < 2; depth++) {
        check_blending(vertex, true, false, depth, 4);
        check_blending(vertex, true, true, depth, 4);
        check_blending(vertex, true, true, depth, 1);
        check_blending(vertex, false, true, depth, 4);
    }
    check_integer_selection(vertex);
    glDeleteVertexArrays(1, &array);
    glDeleteShader(vertex);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display, surface);
    eglDestroyContext(display, context);
    eglTerminate(display);
    puts("Virgl shader tests passed.");
    return 0;
}
