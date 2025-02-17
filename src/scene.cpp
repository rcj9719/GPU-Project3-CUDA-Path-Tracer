#include <iostream>
#include "scene.h"
#include <cstring>
#include <glm/gtc/matrix_inverse.hpp>
#include <glm/gtx/string_cast.hpp>

#include "tiny_obj_loader.h"

Scene::Scene(string filename) {
    cout << "Reading scene from " << filename << " ..." << endl;
    cout << " " << endl;
    char* fname = (char*)filename.c_str();
    fp_in.open(fname);
    if (!fp_in.is_open()) {
        cout << "Error reading from file - aborting!" << endl;
        throw;
    }
    while (fp_in.good()) {
        string line;
        utilityCore::safeGetline(fp_in, line);
        if (!line.empty()) {
            vector<string> tokens = utilityCore::tokenizeString(line);
            if (strcmp(tokens[0].c_str(), "MATERIAL") == 0) {
                loadMaterial(tokens[1]);
                cout << " " << endl;
            } else if (strcmp(tokens[0].c_str(), "OBJECT") == 0) {
                loadGeom(tokens[1]);
                cout << " " << endl;
            } else if (strcmp(tokens[0].c_str(), "CAMERA") == 0) {
                loadCamera();
                cout << " " << endl;
            }
        }
    }
}

int Scene::getImplicitType(Geom* newGeom) {
    string line;
    utilityCore::safeGetline(fp_in, line);
    while (!line.empty() && fp_in.good()) {
        vector<string> tokens = utilityCore::tokenizeString(line);

        /*if ((strcmp(tokens[0].c_str(), "IMP_SPHERE") == 0)||
            (strcmp(tokens[0].c_str(), "IMP_BOOK") == 0) ||
            (strcmp(tokens[0].c_str(), "IMP_PEN") == 0) ||
            (strcmp(tokens[0].c_str(), "IMP_MUG") == 0)
            ) {
            newGeom->implicitobj = ImplicitObj(atof(tokens[0].c_str()));
            return 0;
        }*/
        if (strcmp(tokens[0].c_str(), "IMP_SPHERE") == 0) {
            newGeom->implicitobj = IMP_SPHERE;
            return 0;
        }
        else if (strcmp(tokens[0].c_str(), "IMP_MUG") == 0) {
            newGeom->implicitobj = IMP_MUG;
            return 0;
        }
        else if (strcmp(tokens[0].c_str(), "IMP_COFFEE") == 0) {
            newGeom->implicitobj = IMP_COFFEE;
            return 0;
        }
        else if (strcmp(tokens[0].c_str(), "IMP_BOOKCOVER") == 0) {
            newGeom->implicitobj = IMP_BOOKCOVER;
            return 0;
        }
        else if (strcmp(tokens[0].c_str(), "IMP_BOOKPAGES") == 0) {
            newGeom->implicitobj = IMP_BOOKPAGES;
            return 0;
        }
        else if (strcmp(tokens[0].c_str(), "IMP_LIGHT") == 0) {
            newGeom->implicitobj = IMP_LIGHT;
            return 0;
        }
        else {
            cout << "ERROR: IMPLICIT OBJECT not defined" << endl;
            return -1;
        }

        utilityCore::safeGetline(fp_in, line);
    }

    newGeom->transform = utilityCore::buildTransformationMatrix(
        newGeom->translation, newGeom->rotation, newGeom->scale);
    newGeom->inverseTransform = glm::inverse(newGeom->transform);
    newGeom->invTranspose = glm::inverseTranspose(newGeom->transform);
    return 0;
}

int Scene::linkMaterial(Geom * newGeom) {
    string line;
    utilityCore::safeGetline(fp_in, line);
    if (!line.empty() && fp_in.good()) {
        vector<string> tokens = utilityCore::tokenizeString(line);
        newGeom->materialid = atoi(tokens[1].c_str());
    }
    return 0;
}

int Scene::loadTransformations(Geom* newGeom) {
    string line;
    utilityCore::safeGetline(fp_in, line);
    while (!line.empty() && fp_in.good()) {
        vector<string> tokens = utilityCore::tokenizeString(line);

        //load tranformations
        if (strcmp(tokens[0].c_str(), "TRANS") == 0) {
            newGeom->translation = glm::vec3(atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()));
        }
        else if (strcmp(tokens[0].c_str(), "ROTAT") == 0) {
            newGeom->rotation = glm::vec3(atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()));
        }
        else if (strcmp(tokens[0].c_str(), "SCALE") == 0) {
            newGeom->scale = glm::vec3(atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()));
        }

        utilityCore::safeGetline(fp_in, line);
    }

    newGeom->transform = utilityCore::buildTransformationMatrix(
        newGeom->translation, newGeom->rotation, newGeom->scale);
    newGeom->inverseTransform = glm::inverse(newGeom->transform);
    newGeom->invTranspose = glm::inverseTranspose(newGeom->transform);
    return 0;
}

int Scene::loadObjFile(string objectPath, Geom *newGeom)
{
    tinyobj::ObjReaderConfig reader_config;
    reader_config.mtl_search_path = "./"; // Path to material files

    tinyobj::ObjReader reader;

    if (!reader.ParseFromFile(objectPath, reader_config)) {
        if (!reader.Error().empty()) {
            std::cerr << "TinyObjReader: " << reader.Error();
        }
        exit(1);
    }

    if (!reader.Warning().empty()) {
        std::cout << "TinyObjReader: " << reader.Warning();
    }

    auto& attrib = reader.GetAttrib();
    auto& shapes = reader.GetShapes();
    auto& materials = reader.GetMaterials();
    std::vector<Triangle> triangles;

    glm::vec3 minPos = newGeom->boundingBox.min;
    glm::vec3 maxPos = newGeom->boundingBox.max;

    // Loop over shapess
    for (size_t s = 0; s < shapes.size(); s++) {
        // Loop over faces(polygon)
        size_t index_offset = 0;
        for (size_t f = 0; f < shapes[s].mesh.num_face_vertices.size(); f++) {
            size_t fv = size_t(shapes[s].mesh.num_face_vertices[f]);
            Triangle triangle;

            int vertCnt = 0;
            // Loop over vertices in the face.
            for (size_t v = 0; v < fv; v++) {
                // access to vertex
                tinyobj::index_t idx = shapes[s].mesh.indices[index_offset + v];
                tinyobj::real_t vx = attrib.vertices[3 * size_t(idx.vertex_index) + 0];
                tinyobj::real_t vy = attrib.vertices[3 * size_t(idx.vertex_index) + 1];
                tinyobj::real_t vz = attrib.vertices[3 * size_t(idx.vertex_index) + 2];

                triangle.pos[vertCnt] = glm::vec3(vx, vy, vz);

                if (minPos.x > vx) { minPos.x = vx; }
                if (minPos.y > vy) { minPos.y = vy; }
                if (minPos.z > vz) { minPos.z = vz; }
                
                if (maxPos.x < vx) { maxPos.x = vx; }
                if (maxPos.y < vy) { maxPos.y = vy; }
                if (maxPos.z < vz) { maxPos.z = vz; }

                // Check if `normal_index` is zero or positive. negative = no normal data
                if (idx.normal_index >= 0) {
                    tinyobj::real_t nx = attrib.normals[3 * size_t(idx.normal_index) + 0];
                    tinyobj::real_t ny = attrib.normals[3 * size_t(idx.normal_index) + 1];
                    tinyobj::real_t nz = attrib.normals[3 * size_t(idx.normal_index) + 2];

                    triangle.nor[vertCnt] = glm::vec3(nx, ny, nz);
                }

                //// Check if `texcoord_index` is zero or positive. negative = no texcoord data
                //if (idx.texcoord_index >= 0) {
                //    tinyobj::real_t tx = attrib.texcoords[2 * size_t(idx.texcoord_index) + 0];
                //    tinyobj::real_t ty = attrib.texcoords[2 * size_t(idx.texcoord_index) + 1];

                //    triangle.uv[vertCnt] = glm::vec2(tx, ty);
                //}


                // Optional: vertex colors
                // tinyobj::real_t red   = attrib.colors[3*size_t(idx.vertex_index)+0];
                // tinyobj::real_t green = attrib.colors[3*size_t(idx.vertex_index)+1];
                // tinyobj::real_t blue  = attrib.colors[3*size_t(idx.vertex_index)+2];

                vertCnt++;
                if (vertCnt == 3) { break; }
            }

            triangles.push_back(triangle);
            index_offset += fv;
        }
    }
    newGeom->boundingBox.min = minPos;
    newGeom->boundingBox.max = maxPos;
    newGeom->triCount = triangles.size();
    newGeom->triangles = new Triangle[triangles.size()];
    Triangle* t = newGeom->triangles;
    for (int i = 0; i < triangles.size(); i++) {
        *t = triangles[i];
        t++;
    }
    Triangle* tcpu = newGeom->triangles;

    return 0;
    //printf("\n*****SCENE*****\n");
    //for (int i = 0; i < newGeom->triCount; i++) {
    //    printf("\n %f, %f, %f", tcpu->nor[0].x, tcpu->nor[0].y, tcpu->nor[0].z);
    //    tcpu++;
    //}
    //printf("\n#########\n");
}


int Scene::loadGeom(string objectid) {
    int id = atoi(objectid.c_str());
    if (id != geoms.size()) {
        cout << "ERROR: OBJECT ID does not match expected number of geoms" << endl;
        return -1;
    } else {
        cout << "Loading Geom " << id << "..." << endl;
        Geom newGeom;
        string line;
        int retVal = 0;
        //load object type
        newGeom.boundingBox.min = glm::vec3(INT_MAX, INT_MAX, INT_MAX);
        newGeom.boundingBox.max = glm::vec3(INT_MIN, INT_MIN, INT_MIN);

        utilityCore::safeGetline(fp_in, line);
        if (!line.empty() && fp_in.good()) {
            if (strcmp(line.c_str(), "implicit") == 0) {
                cout << "Creating implicit surface..." << endl;
                newGeom.type = IMPLICIT;
                newGeom.triCount = 0;
                newGeom.triangles = NULL;
                newGeom.dev_triangles = NULL;
                retVal = getImplicitType(&newGeom);
            }
            else if (strcmp(line.c_str(), "obj") == 0) {
                cout << "Loading new obj..." << endl;
                newGeom.type = OBJ;
                utilityCore::safeGetline(fp_in, line);
                if (!line.empty() && fp_in.good()) {
                    retVal =  loadObjFile(line.c_str(), &newGeom);
                }
            } else if (strcmp(line.c_str(), "sphere") == 0) {
                cout << "Creating new sphere..." << endl;
                newGeom.type = SPHERE;
                newGeom.triCount = 0;
                newGeom.triangles = NULL;
                newGeom.dev_triangles = NULL;
            } else if (strcmp(line.c_str(), "cube") == 0) {
                cout << "Creating new cube..." << endl;
                newGeom.triCount = 0;
                newGeom.triangles = NULL;
                newGeom.dev_triangles = NULL;
                newGeom.type = CUBE;
            }
        }

        //link material
        linkMaterial(&newGeom);
        cout << "Connecting Geom " << objectid << " to Material " << newGeom.materialid << "..." << endl;
        //load transformations
        loadTransformations(&newGeom);
        
        geoms.push_back(newGeom);
        return retVal;
    }
}

int Scene::loadCamera() {
    cout << "Loading Camera ..." << endl;
    RenderState &state = this->state;
    Camera &camera = state.camera;
    float fovy;

    //load static properties
    for (int i = 0; i < 7; i++) {
        string line;
        utilityCore::safeGetline(fp_in, line);
        vector<string> tokens = utilityCore::tokenizeString(line);
        if (strcmp(tokens[0].c_str(), "RES") == 0) {
            camera.resolution.x = atoi(tokens[1].c_str());
            camera.resolution.y = atoi(tokens[2].c_str());
        } else if (strcmp(tokens[0].c_str(), "FOVY") == 0) {
            fovy = atof(tokens[1].c_str());
        } else if (strcmp(tokens[0].c_str(), "ITERATIONS") == 0) {
            state.iterations = atoi(tokens[1].c_str());
        } else if (strcmp(tokens[0].c_str(), "DEPTH") == 0) {
            state.traceDepth = atoi(tokens[1].c_str());
        } else if (strcmp(tokens[0].c_str(), "FILE") == 0) {
            state.imageName = tokens[1];
        } else if (strcmp(tokens[0].c_str(), "LENSRADIUS") == 0) {
            camera.lensRadius = atof(tokens[1].c_str());
        } else if (strcmp(tokens[0].c_str(), "FOCALDIST") == 0) {
            camera.focalDist = atof(tokens[1].c_str());
        }
    }

    string line;
    utilityCore::safeGetline(fp_in, line);
    while (!line.empty() && fp_in.good()) {
        vector<string> tokens = utilityCore::tokenizeString(line);
        if (strcmp(tokens[0].c_str(), "EYE") == 0) {
            camera.position = glm::vec3(atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()));
        } else if (strcmp(tokens[0].c_str(), "LOOKAT") == 0) {
            camera.lookAt = glm::vec3(atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()));
        } else if (strcmp(tokens[0].c_str(), "UP") == 0) {
            camera.up = glm::vec3(atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()));
        }

        utilityCore::safeGetline(fp_in, line);
    }

    //calculate fov based on resolution
    float yscaled = tan(fovy * (PI / 180));
    float xscaled = (yscaled * camera.resolution.x) / camera.resolution.y;
    float fovx = (atan(xscaled) * 180) / PI;
    camera.fov = glm::vec2(fovx, fovy);

    camera.right = glm::normalize(glm::cross(camera.view, camera.up));
    camera.pixelLength = glm::vec2(2 * xscaled / (float)camera.resolution.x,
                                   2 * yscaled / (float)camera.resolution.y);

    camera.view = glm::normalize(camera.lookAt - camera.position);

    //set up render camera stuff
    int arraylen = camera.resolution.x * camera.resolution.y;
    state.image.resize(arraylen);
    std::fill(state.image.begin(), state.image.end(), glm::vec3());

    cout << "Loaded camera!" << endl;
    return 1;
}

int Scene::loadMaterial(string materialid) {
    int id = atoi(materialid.c_str());
    if (id != materials.size()) {
        cout << "ERROR: MATERIAL ID does not match expected number of materials" << endl;
        return -1;
    } else {
        cout << "Loading Material " << id << "..." << endl;
        Material newMaterial;

        //load static properties
        for (int i = 0; i < 8; i++) {
            string line;
            utilityCore::safeGetline(fp_in, line);
            vector<string> tokens = utilityCore::tokenizeString(line);
            if (strcmp(tokens[0].c_str(), "RGB") == 0) {
                glm::vec3 color( atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()) );
                newMaterial.color = color;
            } else if (strcmp(tokens[0].c_str(), "SPECEX") == 0) {
                newMaterial.specular.exponent = atof(tokens[1].c_str());
            } else if (strcmp(tokens[0].c_str(), "SPECRGB") == 0) {
                glm::vec3 specColor(atof(tokens[1].c_str()), atof(tokens[2].c_str()), atof(tokens[3].c_str()));
                newMaterial.specular.color = specColor;
            } else if (strcmp(tokens[0].c_str(), "REFL") == 0) {
                newMaterial.hasReflective = atof(tokens[1].c_str());
            } else if (strcmp(tokens[0].c_str(), "REFR") == 0) {
                newMaterial.hasRefractive = atof(tokens[1].c_str());
            } else if (strcmp(tokens[0].c_str(), "REFRIOR") == 0) {
                newMaterial.indexOfRefraction = atof(tokens[1].c_str());
            } else if (strcmp(tokens[0].c_str(), "EMITTANCE") == 0) {
                newMaterial.emittance = atof(tokens[1].c_str());
            } else if (strcmp(tokens[0].c_str(), "PROTEX") == 0) {
                newMaterial.proceduralTex = atof(tokens[1].c_str());
            }
        }
        materials.push_back(newMaterial);
        return 1;
    }
}
