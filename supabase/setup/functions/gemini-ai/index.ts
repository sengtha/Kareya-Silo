import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { GoogleGenAI, Type } from "npm:@google/genai@0.2.0";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { action, prompt, context, type, imageBase64, year, mimeType, title, dept, eventsJson } = await req.json();
    const apiKey = Deno.env.get('GEMINI_API_KEY');
    
    if (!apiKey) {
      throw new Error('Missing Gemini API Key');
    }

    const ai = new GoogleGenAI({ apiKey });
    
    // Model Selection logic based on task
    const textModel = 'gemini-3-flash-preview'; 
    
    let resultText = '';
    let resultData = null;

    switch (action) {
      case 'generate-text': {
        let systemInstruction = "";
        if (type === 'template') {
            systemInstruction = "You are a professional document architect. Convert descriptions into clean Markdown. Optimized for readability. Return raw Markdown only.";
        } else if (type === 'html_content') {
            systemInstruction = "You are an expert copywriter. Generate rich Markdown content. Structure logically with headers and lists. Return raw Markdown only.";
        } else {
            systemInstruction = `You are KAREYA, an intelligent AI office manager. Tone: Professional, concise, helpful. Context: ${context || ''}`;
        }

        const response = await ai.models.generateContent({
          model: textModel,
          contents: [{ parts: [{ text: prompt }] }],
          config: { systemInstruction }
        });
        resultText = response.text || '';
        break;
      }

      case 'generate-template-image': {
        const p = "Replicate this document layout in HTML using inline Tailwind CSS. Use placeholders like {{companyName}}, {{date}}, {{items}}, and {{total}}. Return ONLY the HTML string.";
        const response = await ai.models.generateContent({
            model: textModel,
            contents: {
                parts: [
                    { inlineData: { mimeType: 'image/png', data: imageBase64 } },
                    { text: p }
                ]
            }
        });
        resultText = (response.text || "").replace(/```html/g, '').replace(/```/g, '').trim();
        break;
      }

      case 'extract-holidays': {
        const p = `Identify all public holidays for ${year} from this image. Extract the date and name. Ensure the date is in YYYY-MM-DD format. Return STRICTLY as a JSON array.`;
        const response = await ai.models.generateContent({
            model: textModel,
            contents: {
                parts: [
                    { inlineData: { mimeType: mimeType || 'image/png', data: imageBase64 } },
                    { text: p }
                ]
            },
            config: { 
                responseMimeType: "application/json",
                responseSchema: {
                    type: Type.ARRAY,
                    items: {
                        type: Type.OBJECT,
                        properties: {
                            name: { type: Type.STRING },
                            date: { type: Type.STRING },
                        },
                        required: ["name", "date"],
                    },
                },
            }
        });
        resultData = JSON.parse(response.text || "[]");
        break;
      }

      case 'generate-job-desc': {
        const p = `Write a professional job description for "${title}" in the "${dept}" department. Include role summary, responsibilities, and key requirements. Return Markdown.`;
        const response = await ai.models.generateContent({
            model: textModel,
            contents: [{ parts: [{ text: p }] }],
            config: { systemInstruction: "You are an expert HR copywriter." }
        });
        resultText = response.text || '';
        break;
      }

      case 'summarize-schedule': {
        const p = `Summarize the following schedule for a text-to-speech engine: ${eventsJson}. Make it sound like a friendly morning briefing.`;
        const response = await ai.models.generateContent({
            model: textModel,
            contents: [{ parts: [{ text: p }] }]
        });
        resultText = response.text || '';
        break;
      }

      default:
        throw new Error('Invalid action');
    }

    const responsePayload = resultData ? { holidays: resultData } : { text: resultText };

    return new Response(JSON.stringify(responsePayload), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
